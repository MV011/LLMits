import Foundation

/// Pre-resolved Antigravity server info (discovered BEFORE entering async task groups).
struct AntigravityServerInfo: Sendable {
    let pid: String
    let csrfToken: String
    let extensionPort: Int?
}

/// Discovers Antigravity desktop app language servers. MUST be called outside of
/// Swift concurrency task groups — Process.waitUntilExit() deadlocks
/// inside the cooperative thread pool executor.
func discoverAntigravityServers() -> [AntigravityServerInfo] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ax", "-o", "pid=,command="]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        debugLog("[Antigravity] ps failed: \(error)")
        return []
    }

    // CRITICAL: Read pipe BEFORE waitUntilExit to avoid pipe buffer deadlock.
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    var servers: [AntigravityServerInfo] = []

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("language_server") && trimmed.contains("antigravity") else {
            continue
        }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let pid = parts.first else { continue }

        var csrfToken = ""
        if let r = trimmed.range(of: "--csrf_token ") {
            csrfToken = String(trimmed[r.upperBound...].split(separator: " ").first ?? "")
        }

        var extPort: Int? = nil
        if let r = trimmed.range(of: "--extension_server_port ") {
            extPort = Int(trimmed[r.upperBound...].split(separator: " ").first ?? "")
        }

        guard !csrfToken.isEmpty else { continue }
        servers.append(AntigravityServerInfo(pid: String(pid), csrfToken: csrfToken, extensionPort: extPort))
    }

    return servers
}

/// Fetches Antigravity usage via two strategies:
///
/// 1. **Primary: Direct API** — Uses the cloudcode-pa.googleapis.com API with
///    OAuth tokens from ~/.gemini/oauth_creds.json (shared by both the Antigravity
///    CLI `agy` and the desktop app). This works regardless of which surface is running.
///
/// 2. **Fallback: Language Server** — Probes the Antigravity desktop app's local
///    language server via GetUserStatus. Only used when OAuth creds are unavailable.
///
/// Groups models into 3 buckets: Gemini Pro, Gemini Flash, Flash Lite.
/// Also surfaces AI credit balances when available.
struct AntigravityService: UsageService {
    private static let providerKey = "antigravity"
    private static let codeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal"

    /// Known daily request limits per tier
    private static let tierLimits: [String: Int] = [
        "g1-ultra-tier": 2000,
        "enterprise-tier": 2000,
        "workspace-ai-ultra-tier": 2000,
        "g1-pro-tier": 1500,
        "standard-tier": 1500,
        "free-tier": 1000,
    ]

    var cachedServers: [AntigravityServerInfo] = []

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            let remaining = RateLimiter.shared.remainingSeconds(Self.providerKey)
            debugLog("[Antigravity] rate limited for \(remaining)s more")
            throw ServiceError.httpError(429)
        }

        // Strategy 1: Direct API via OAuth (works for both CLI and desktop app)
        if let oauthCreds = try? GoogleOAuthHelper.readOAuthCreds() {
            do {
                var accessToken = try await GoogleOAuthHelper.resolveAccessToken(oauthCreds)
                do {
                    let result = try await fetchViaDirectAPI(accessToken: accessToken)
                    RateLimiter.shared.clear(Self.providerKey)
                    return result
                } catch ServiceError.httpError(let code) where code == 401 || code == 403 {
                    // Token rejected — force-refresh and retry once
                    debugLog("[Antigravity] got \(code), force-refreshing token and retrying")
                    guard let refreshToken = oauthCreds.refreshToken else {
                        throw ServiceError.noCredentials(
                            "Antigravity token expired. Run 'agy' to refresh credentials."
                        )
                    }
                    do {
                        accessToken = try await GoogleOAuthHelper.refreshAndPersist(refreshToken: refreshToken)
                    } catch {
                        debugLog("[Antigravity] token refresh failed: \(error)")
                        throw ServiceError.noCredentials(
                            "Antigravity token expired and refresh failed. Run 'agy' to re-authenticate."
                        )
                    }
                    let result = try await fetchViaDirectAPI(accessToken: accessToken)
                    RateLimiter.shared.clear(Self.providerKey)
                    return result
                }
            } catch {
                debugLog("[Antigravity] direct API failed: \(error), trying language server fallback")
                // Fall through to language server probe
            }
        }

        // Strategy 2: Language Server probe (desktop app only)
        return try await fetchViaLanguageServer()
    }

    // MARK: - Strategy 1: Direct API

    private struct ProjectInfo {
        let projectId: String
        let tier: String      // e.g. "g1-ultra-tier"
        let tierName: String  // e.g. "Gemini Code Assist in Google One AI Ultra"
    }

    private func fetchViaDirectAPI(accessToken: String) async throws -> [UsageGroup] {
        let projectInfo = try await loadCodeAssist(accessToken: accessToken)
        let quotaResponse = try await retrieveUserQuota(accessToken: accessToken, projectId: projectInfo.projectId)
        return buildUsageGroups(
            buckets: quotaResponse.buckets,
            tier: projectInfo.tier,
            tierName: projectInfo.tierName,
            email: GoogleOAuthHelper.readAccountEmail()
        )
    }

    private func loadCodeAssist(accessToken: String) async throws -> ProjectInfo {
        let url = URL(string: "\(Self.codeAssistEndpoint):loadCodeAssist")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
            RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
            throw ServiceError.httpError(429)
        }

        guard httpResponse.statusCode == 200 else {
            throw ServiceError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON from loadCodeAssist")
        }

        guard let projectId = json["cloudaicompanionProject"] as? String else {
            throw ServiceError.parseError("No project ID in loadCodeAssist response")
        }

        // Prefer paidTier (subscription) over currentTier (base)
        let paidTier = json["paidTier"] as? [String: Any]
        let currentTier = json["currentTier"] as? [String: Any]
        let tier = (paidTier?["id"] as? String) ?? (currentTier?["id"] as? String) ?? "standard-tier"
        let tierName = (paidTier?["name"] as? String) ?? (currentTier?["name"] as? String) ?? "Antigravity"

        return ProjectInfo(projectId: projectId, tier: tier, tierName: tierName)
    }

    private struct QuotaBucket {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String?
    }

    private struct QuotaResponse {
        let buckets: [QuotaBucket]
    }

    private func retrieveUserQuota(accessToken: String, projectId: String) async throws -> QuotaResponse {
        let url = URL(string: "\(Self.codeAssistEndpoint):retrieveUserQuota")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": projectId])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
            RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
            throw ServiceError.httpError(429)
        }

        guard httpResponse.statusCode == 200 else {
            throw ServiceError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBuckets = json["buckets"] as? [[String: Any]] else {
            throw ServiceError.parseError("Invalid JSON from retrieveUserQuota")
        }

        let buckets = rawBuckets.compactMap { bucket -> QuotaBucket? in
            guard let modelId = bucket["modelId"] as? String else { return nil }
            // Handle both Double (0.2) and Int (1) JSON values
            let remainingFraction: Double
            if let d = bucket["remainingFraction"] as? Double {
                remainingFraction = d
            } else if let i = bucket["remainingFraction"] as? Int {
                remainingFraction = Double(i)
            } else {
                return nil
            }
            return QuotaBucket(
                modelId: modelId,
                remainingFraction: remainingFraction,
                resetTime: bucket["resetTime"] as? String
            )
        }

        return QuotaResponse(buckets: buckets)
    }

    // MARK: - Build Usage Groups (from direct API)

    private enum ModelCategory: String, CaseIterable {
        case pro, flash, lite
        var displayName: String {
            switch self {
            case .pro: return "Pro"
            case .flash: return "Flash"
            case .lite: return "Flash Lite"
            }
        }
    }

    private func buildUsageGroups(
        buckets: [QuotaBucket],
        tier: String,
        tierName: String,
        email: String
    ) -> [UsageGroup] {
        // Determine daily limit from tier
        let dailyLimit = Self.tierLimits[tier] ?? 1000

        // Group API buckets by our three categories
        var bucketData: [ModelCategory: (remainingFraction: Double, resetTime: Date?, models: [String])] = [:]

        for bucket in buckets {
            let category = classifyModel(bucket.modelId)
            let resetDate = GoogleOAuthHelper.parseISO8601(bucket.resetTime ?? "")

            if let existing = bucketData[category] {
                var models = existing.models
                models.append(bucket.modelId)
                bucketData[category] = (existing.remainingFraction, existing.resetTime ?? resetDate, models)
            } else {
                bucketData[category] = (bucket.remainingFraction, resetDate, [bucket.modelId])
            }
        }

        var limits: [UsageLimit] = []

        for category in [ModelCategory.pro, .flash, .lite] {
            let data = bucketData[category]
            let remainingFraction = data?.remainingFraction ?? 1.0
            let usedFraction = 1.0 - remainingFraction
            let usedRequests = Int(round(usedFraction * Double(dailyLimit)))
            let resetDate = data?.resetTime

            var parts: [String] = []
            parts.append("\(usedRequests) / \(dailyLimit) req")

            if let reset = resetDate, reset > Date() {
                let remaining = reset.timeIntervalSinceNow
                if let formatted = TimeFormatter.formatRemaining(remaining) {
                    parts.append("Resets in \(formatted)")
                }
            }

            limits.append(UsageLimit(
                name: category.displayName,
                percentUsed: usedFraction,
                detail: parts.joined(separator: " · "),
                windowType: .perDay
            ))
        }

        // Use tier name as the group header (e.g. "Google One AI Ultra")
        let shortTierName = tierName
            .replacingOccurrences(of: "Gemini Code Assist in ", with: "")
            .replacingOccurrences(of: "Gemini Code Assist", with: "Code Assist")

        return [UsageGroup(name: shortTierName, limits: limits)]
    }

    private func classifyModel(_ name: String) -> ModelCategory {
        let lower = name.lowercased()
        if lower.contains("flash-lite") || lower.contains("flash_lite") || lower.contains("lite") {
            return .lite
        }
        if lower.contains("pro") {
            return .pro
        }
        return .flash
    }

    // MARK: - Strategy 2: Language Server Fallback

    private func fetchViaLanguageServer() async throws -> [UsageGroup] {
        debugLog("[Antigravity] fetchViaLanguageServer with \(cachedServers.count) cached servers")

        for (i, server) in cachedServers.enumerated() {
            guard let ep = server.extensionPort else { continue }
            let portsToTry = [ep + 1, ep + 2, ep, ep + 3, ep + 8, ep + 9, ep + 10]

            for port in portsToTry {
                debugLog("[Antigravity] trying server[\(i)] port \(port)...")
                do {
                    let groups = try await fetchQuotaWithTimeout(port: port, csrfToken: server.csrfToken, timeoutSeconds: 3)
                    debugLog("[Antigravity] SUCCESS on port \(port)")
                    return groups
                } catch {
                    debugLog("[Antigravity] port \(port) failed: \(error)")
                    continue
                }
            }
        }

        if cachedServers.isEmpty {
            throw ServiceError.processNotFound("Antigravity is not running. Launch it or install the CLI (agy) to see usage data.")
        }
        throw ServiceError.processNotFound("Antigravity is running but could not connect to language server.")
    }

    // MARK: - Language Server Quota Fetch

    private func fetchQuotaWithTimeout(port: Int, csrfToken: String, timeoutSeconds: UInt64) async throws -> [UsageGroup] {
        try await withThrowingTaskGroup(of: [UsageGroup].self) { group in
            group.addTask {
                try await self.fetchQuota(port: port, csrfToken: csrfToken)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw ServiceError.processNotFound("timeout after \(timeoutSeconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func fetchQuota(port: Int, csrfToken: String) async throws -> [UsageGroup] {
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/GetUserStatus")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en"]
        ])
        request.timeoutInterval = 3

        let (data, response) = try await Self._insecureSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try parseLanguageServerResponse(data)
    }

    // MARK: - Language Server Response Parsing

    private func parseLanguageServerResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid response from Antigravity language server")
        }

        let userStatus = json["userStatus"] as? [String: Any] ?? json
        let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any] ?? [:]
        let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] ?? []

        struct ModelQuota {
            let label: String
            let remainingFraction: Double
            let resetTime: String?
        }

        var allModels: [ModelQuota] = []
        for config in configs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any] else { continue }
            let remaining: Double
            if let d = quotaInfo["remainingFraction"] as? Double ?? quotaInfo["remaining_fraction"] as? Double {
                remaining = d
            } else if let i = quotaInfo["remainingFraction"] as? Int ?? quotaInfo["remaining_fraction"] as? Int {
                remaining = Double(i)
            } else {
                continue
            }
            let label = config["label"] as? String ?? config["modelLabel"] as? String ?? "Unknown"
            let resetStr = quotaInfo["resetTime"] as? String ?? quotaInfo["reset_time"] as? String
            allModels.append(ModelQuota(label: label, remainingFraction: remaining, resetTime: resetStr))
        }

        // Group into 3 buckets
        enum LSBucket { case geminiPro, geminiFlash, cloud }

        func classifyLSModel(_ label: String) -> LSBucket {
            let lower = label.lowercased()
            if lower.contains("gemini") && lower.contains("pro") { return .geminiPro }
            if lower.contains("gemini") && lower.contains("flash") { return .geminiFlash }
            return .cloud
        }

        var geminiPro: [ModelQuota] = []
        var geminiFlash: [ModelQuota] = []
        var cloud: [ModelQuota] = []

        for model in allModels {
            switch classifyLSModel(model.label) {
            case .geminiPro: geminiPro.append(model)
            case .geminiFlash: geminiFlash.append(model)
            case .cloud: cloud.append(model)
            }
        }

        var limits: [UsageLimit] = []

        func buildLSLimit(name: String, models: [ModelQuota]) -> UsageLimit? {
            guard let rep = models.first else { return nil }
            let (adjustedUsed, resetDetail) = TimeFormatter.adjustForStaleReset(
                percentUsed: 1.0 - rep.remainingFraction,
                resetDateString: rep.resetTime,
                windowSeconds: TimeFormatter.fiveHourSeconds
            )
            let modelsStr = models.map(\.label).joined(separator: ", ")
            var detail = modelsStr
            if let rd = resetDetail, !rd.isEmpty {
                detail = "\(modelsStr) · \(rd)"
            }
            return UsageLimit(name: name, percentUsed: adjustedUsed, detail: detail, windowType: .fiveHour)
        }

        if let l = buildLSLimit(name: "Gemini Pro", models: geminiPro) { limits.append(l) }
        if let l = buildLSLimit(name: "Gemini Flash", models: geminiFlash) { limits.append(l) }
        if let l = buildLSLimit(name: "Cloud", models: cloud) { limits.append(l) }

        // Add credits info
        let creditLimits = parseCredits(userStatus)
        limits.append(contentsOf: creditLimits)

        if limits.isEmpty {
            let email = userStatus["email"] as? String ?? "Connected"
            return [UsageGroup(name: "Antigravity", limits: [
                UsageLimit(name: email, percentUsed: 0, detail: "No quota data", windowType: .unknown)
            ])]
        }

        return [UsageGroup(name: "Antigravity", limits: limits)]
    }

    // MARK: - Credits

    private func parseCredits(_ userStatus: [String: Any]) -> [UsageLimit] {
        var credits: [UsageLimit] = []

        if let userTier = userStatus["userTier"] as? [String: Any],
           let availableCredits = userTier["availableCredits"] as? [[String: Any]] {
            for credit in availableCredits {
                if let creditType = credit["creditType"] as? String,
                   let amountStr = credit["creditAmount"] as? String,
                   let amount = Int(amountStr) {
                    let name = creditType
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized
                        .replacingOccurrences(of: "Google One Ai", with: "Google One AI")
                    credits.append(UsageLimit(
                        name: name,
                        percentUsed: 0,
                        detail: formatCredits(amount) + " remaining",
                        windowType: .unknown
                    ))
                }
            }
        }

        return credits
    }

    private func formatCredits(_ amount: Int) -> String {
        if amount >= 1000 {
            let k = Double(amount) / 1000.0
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.1fK", k)
        }
        return "\(amount)"
    }

    // MARK: - TLS (localhost self-signed cert)

    private static let _insecureSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }()
}

/// Allows self-signed TLS certs for localhost connections only.
private class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}
