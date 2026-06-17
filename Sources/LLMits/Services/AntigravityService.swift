import Foundation

/// Pre-resolved Antigravity server info (discovered BEFORE entering async task groups).
struct AntigravityServerInfo: Sendable {
    let pid: String
    let csrfToken: String
    let extensionPort: Int?
    let listeningPorts: [Int]
}

/// Discovers Antigravity desktop app and `agy` CLI language servers. MUST be called
/// outside of Swift concurrency task groups — Process.waitUntilExit() deadlocks
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
        guard !trimmed.isEmpty else { continue }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        guard let pid = parts.first else { continue }
        let command = parts.count > 1 ? String(parts[1]) : trimmed

        guard isAntigravityLanguageServer(command) || isAgyServerProcess(command) else {
            continue
        }

        var csrfToken = ""
        if let r = command.range(of: "--csrf_token ") {
            csrfToken = String(command[r.upperBound...].split(separator: " ").first ?? "")
        }

        var extPort: Int? = nil
        if let r = command.range(of: "--extension_server_port ") {
            extPort = Int(command[r.upperBound...].split(separator: " ").first ?? "")
        }

        let listeningPorts = discoverListeningPorts(pid: String(pid))
        debugLog("[Antigravity] discovered pid=\(pid) csrf=\(csrfToken.isEmpty ? "none" : "set") ports=\(listeningPorts) extPort=\(extPort.map(String.init) ?? "nil")")

        servers.append(AntigravityServerInfo(
            pid: String(pid),
            csrfToken: csrfToken,
            extensionPort: extPort,
            listeningPorts: listeningPorts
        ))
    }

    return servers
}

private func isAntigravityLanguageServer(_ command: String) -> Bool {
    let lower = command.lowercased()
    guard lower.contains("language_server") else { return false }
    return lower.contains("antigravity")
        || lower.contains("antigravity-ide")
        || lower.contains("/antigravity/")
}

private func isAgyServerProcess(_ command: String) -> Bool {
    let parts = command.split(separator: " ", maxSplits: 1)
    let basename = parts.first.map(String.init) ?? command
    if basename.hasSuffix("/agy") || basename == "agy" { return true }
    return command.contains("/agy") || command.contains(" agy ")
}

private func discoverListeningPorts(pid: String) -> [Int] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    guard (try? process.run()) != nil else { return [] }

    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let output = String(data: outputData, encoding: .utf8) ?? ""
    var ports: [Int] = []

    for line in output.components(separatedBy: "\n") {
        // Example: agy 12345 user 8u IPv4 ... TCP 127.0.0.1:54321 (LISTEN)
        guard let range = line.range(of: "127.0.0.1:") else { continue }
        let after = line[range.upperBound...]
        let portStr = after.prefix(while: { $0.isNumber })
        if let port = Int(portStr) {
            ports.append(port)
        }
    }

    return Array(Set(ports)).sorted()
}

/// Fetches Antigravity usage via two strategies:
///
/// 1. **Primary: Language Server** — `RetrieveUserQuotaSummary` on the Antigravity app
///    or `agy` CLI local server (Gemini Models / Claude+GPT with Weekly + 5h limits).
///    Falls back to `GetUserStatus` when the summary endpoint is unavailable.
///
/// 2. **Fallback: Cloud API** — `retrieveUserQuotaSummary` or `fetchAvailableModels`
///    with OAuth creds when no local server is reachable.
struct AntigravityService: UsageService {
    private static let providerKey = "antigravity"
    private static let codeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal"

    var cachedServers: [AntigravityServerInfo] = []

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            let remaining = RateLimiter.shared.remainingSeconds(Self.providerKey)
            debugLog("[Antigravity] rate limited for \(remaining)s more")
            throw ServiceError.httpError(429)
        }

        let servers = cachedServers.isEmpty ? discoverAntigravityServers() : cachedServers

        // Strategy 1: Language server (Antigravity IDE / agy local quota surface)
        if !servers.isEmpty {
            do {
                let result = try await fetchViaLanguageServer(servers: servers)
                RateLimiter.shared.clear(Self.providerKey)
                return result
            } catch {
                debugLog("[Antigravity] language server failed: \(error), trying cloud models API")
            }
        }

        // Strategy 2: Cloud quota summary / models API
        if let oauthCreds = try? GoogleOAuthHelper.readOAuthCreds() {
            do {
                var accessToken = try await GoogleOAuthHelper.resolveAccessToken(oauthCreds)
                do {
                    let result = try await fetchViaCloudQuota(accessToken: accessToken)
                    RateLimiter.shared.clear(Self.providerKey)
                    return result
                } catch ServiceError.httpError(let code) where code == 401 || code == 403 {
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
                    let result = try await fetchViaCloudQuota(accessToken: accessToken)
                    RateLimiter.shared.clear(Self.providerKey)
                    return result
                }
            } catch {
                debugLog("[Antigravity] cloud quota API failed: \(error)")
                throw error
            }
        }

        if servers.isEmpty {
            throw ServiceError.processNotFound(
                "Antigravity is not running. Keep `agy` open or launch the desktop app, then refresh."
            )
        }
        throw ServiceError.processNotFound("Antigravity is running but could not connect to quota API.")
    }

    // MARK: - Strategy 2: Cloud API

    private func fetchViaCloudQuota(accessToken: String) async throws -> [UsageGroup] {
        // Prefer the same quota-summary shape agy uses when available over OAuth.
        do {
            return try await fetchCloudQuotaSummary(accessToken: accessToken)
        } catch {
            debugLog("[Antigravity] cloud retrieveUserQuotaSummary failed: \(error), trying fetchAvailableModels")
        }
        return try await fetchViaCloudModels(accessToken: accessToken)
    }

    private func fetchCloudQuotaSummary(accessToken: String) async throws -> [UsageGroup] {
        let endpoints = [
            "\(Self.codeAssistEndpoint):retrieveUserQuotaSummary",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        ]

        var lastError: Error = ServiceError.invalidResponse
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            request.httpBody = "{}".data(using: .utf8)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }
                guard httpResponse.statusCode == 200 else {
                    throw ServiceError.httpError(httpResponse.statusCode)
                }
                return try parseQuotaSummaryResponse(data)
            } catch {
                debugLog("[Antigravity] cloud quota summary at \(endpoint) failed: \(error)")
                lastError = error
            }
        }
        throw lastError
    }

    private func fetchViaCloudModels(accessToken: String) async throws -> [UsageGroup] {
        let endpoints = [
            "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
            "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
        ]

        var lastError: Error = ServiceError.invalidResponse

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10
            request.httpBody = "{}".data(using: .utf8)

            do {
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

                return try parseCloudModelsResponse(data)
            } catch {
                debugLog("[Antigravity] fetchAvailableModels at \(endpoint) failed: \(error)")
                lastError = error
            }
        }

        throw lastError
    }

    private func parseCloudModelsResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON from fetchAvailableModels")
        }

        var allModels: [ModelQuotaEntry] = []
        for (modelId, value) in models {
            guard let model = value as? [String: Any] else { continue }
            if model["isInternal"] as? Bool == true { continue }

            let displayName = (model["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if displayName.isEmpty { continue }

            let label = displayName
            let lowerId = modelId.lowercased()
            if lowerId.contains("chat_") || lowerId.contains("tab_") || lowerId.contains("autocomplete") {
                continue
            }

            guard let quotaInfo = model["quotaInfo"] as? [String: Any] else { continue }
            let remaining: Double
            if let d = quotaInfo["remainingFraction"] as? Double {
                remaining = d
            } else if let i = quotaInfo["remainingFraction"] as? Int {
                remaining = Double(i)
            } else {
                continue
            }

            let resetStr = quotaInfo["resetTime"] as? String
            allModels.append(ModelQuotaEntry(label: label, remainingFraction: remaining, resetTime: resetStr))
        }

        return buildAntigravityUsageGroups(from: allModels)
    }

    // MARK: - Strategy 1: Language Server

    private func fetchViaLanguageServer(servers: [AntigravityServerInfo]) async throws -> [UsageGroup] {
        debugLog("[Antigravity] fetchViaLanguageServer with \(servers.count) servers")

        for (i, server) in servers.enumerated() {
            var portsToTry = server.listeningPorts
            if let ep = server.extensionPort {
                portsToTry.append(contentsOf: [ep + 1, ep + 2, ep, ep + 3, ep + 8, ep + 9, ep + 10])
            }
            portsToTry = Array(Set(portsToTry)).sorted()

            for port in portsToTry {
                debugLog("[Antigravity] trying server[\(i)] pid=\(server.pid) port \(port)...")
                do {
                    let groups = try await fetchQuotaWithTimeout(
                        port: port,
                        csrfToken: server.csrfToken,
                        timeoutSeconds: 3
                    )
                    debugLog("[Antigravity] SUCCESS on port \(port)")
                    return groups
                } catch {
                    debugLog("[Antigravity] port \(port) failed: \(error)")
                    continue
                }
            }
        }

        if servers.isEmpty {
            throw ServiceError.processNotFound("Antigravity is not running. Launch it or run 'agy' to see usage data.")
        }
        throw ServiceError.processNotFound("Antigravity is running but could not connect to language server.")
    }

    private func buildAntigravityUsageGroups(from models: [ModelQuotaEntry]) -> [UsageGroup] {
        enum LSBucket { case geminiPro, geminiFlash, cloud }

        func classifyLSModel(_ label: String) -> LSBucket {
            let lower = label.lowercased()
            if lower.contains("gemini") && lower.contains("pro") { return .geminiPro }
            if lower.contains("gemini") && lower.contains("flash") { return .geminiFlash }
            return .cloud
        }

        var geminiPro: [ModelQuotaEntry] = []
        var geminiFlash: [ModelQuotaEntry] = []
        var cloud: [ModelQuotaEntry] = []

        for model in models {
            switch classifyLSModel(model.label) {
            case .geminiPro: geminiPro.append(model)
            case .geminiFlash: geminiFlash.append(model)
            case .cloud: cloud.append(model)
            }
        }

        var limits: [UsageLimit] = []

        func buildLSLimit(name: String, models: [ModelQuotaEntry]) -> UsageLimit? {
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

        if limits.isEmpty {
            return [UsageGroup(name: "Antigravity", limits: [
                UsageLimit(name: "Connected", percentUsed: 0, detail: "No quota data", windowType: .unknown)
            ])]
        }

        return [UsageGroup(name: "Antigravity", limits: limits)]
    }

    private struct ModelQuotaEntry {
        let label: String
        let remainingFraction: Double
        let resetTime: String?
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
        // Primary: same endpoint agy CLI uses (grouped Weekly + 5h limits).
        do {
            let data = try await postLocalLS(
                port: port,
                csrfToken: csrfToken,
                method: "RetrieveUserQuotaSummary",
                body: [:]
            )
            return try parseQuotaSummaryResponse(data)
        } catch {
            debugLog("[Antigravity] RetrieveUserQuotaSummary on port \(port) failed: \(error), trying GetUserStatus")
        }

        let data = try await postLocalLS(
            port: port,
            csrfToken: csrfToken,
            method: "GetUserStatus",
            body: [
                "metadata": ["ideName": "antigravity", "extensionName": "antigravity", "locale": "en"]
            ]
        )
        return try parseLanguageServerResponse(data)
    }

    private func postLocalLS(port: Int, csrfToken: String, method: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !csrfToken.isEmpty {
            request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.isEmpty
            ? "{}".data(using: .utf8)
            : try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 3

        let (data, response) = try await Self._insecureSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }

    // MARK: - Quota Summary Parsing (agy CLI format)

    private func parseQuotaSummaryResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid quota summary JSON")
        }

        if let code = json["code"] as? Int, code != 0 {
            let msg = json["message"] as? String ?? "Quota summary API error"
            throw ServiceError.parseError(msg)
        }

        let payload = (json["response"] as? [String: Any])
            ?? (json["summary"] as? [String: Any])
            ?? json

        guard let groups = payload["groups"] as? [[String: Any]], !groups.isEmpty else {
            throw ServiceError.parseError("Missing quota groups in summary")
        }

        var usageGroups: [UsageGroup] = []
        for group in groups {
            let groupName = (group["displayName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Quota"
            guard let buckets = group["buckets"] as? [[String: Any]], !buckets.isEmpty else { continue }

            var limits: [UsageLimit] = []
            for bucket in buckets {
                if let limit = parseQuotaSummaryBucket(bucket) {
                    limits.append(limit)
                }
            }
            if !limits.isEmpty {
                usageGroups.append(UsageGroup(name: groupName, limits: limits))
            }
        }

        guard !usageGroups.isEmpty else {
            throw ServiceError.parseError("No usable quota buckets")
        }
        return usageGroups
    }

    private func parseQuotaSummaryBucket(_ bucket: [String: Any]) -> UsageLimit? {
        let bucketId = (bucket["bucketId"] as? String) ?? ""
        let displayName = (bucket["displayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? bucketId
        guard !displayName.isEmpty else { return nil }
        if bucket["disabled"] as? Bool == true { return nil }

        let remainingFraction = resolveRemainingFraction(from: bucket)
        guard let remaining = remainingFraction else { return nil }

        let resetStr = bucket["resetTime"] as? String
        let windowType = inferWindowType(bucketId: bucketId, displayName: displayName)
        let windowSeconds = windowType == .weekly
            ? TimeFormatter.weeklySeconds
            : TimeFormatter.fiveHourSeconds

        let (adjustedUsed, resetDetail) = TimeFormatter.adjustForStaleReset(
            percentUsed: 1.0 - remaining,
            resetDateString: resetStr,
            windowSeconds: windowSeconds
        )

        var detail = bucket["description"] as? String
        if let rd = resetDetail, !rd.isEmpty {
            detail = detail.map { "\($0) · \(rd)" } ?? rd
        }

        return UsageLimit(
            name: displayName,
            percentUsed: adjustedUsed,
            detail: detail,
            windowType: windowType
        )
    }

    private func resolveRemainingFraction(from bucket: [String: Any]) -> Double? {
        if let rf = bucket["remainingFraction"] as? Double { return rf }
        if let rf = bucket["remainingFraction"] as? Int { return Double(rf) }
        guard let remaining = bucket["remaining"] as? [String: Any] else { return nil }
        if let rf = remaining["remainingFraction"] as? Double { return rf }
        if let rf = remaining["remainingFraction"] as? Int { return Double(rf) }
        if let oneofCase = remaining["case"] as? String, oneofCase == "remainingFraction" {
            if let val = remaining["value"] as? Double { return val }
            if let val = remaining["value"] as? Int { return Double(val) }
        }
        return nil
    }

    private func inferWindowType(bucketId: String, displayName: String) -> UsageLimit.WindowType {
        let combined = (bucketId + " " + displayName).lowercased()
        if combined.contains("weekly") || combined.contains("7d") || combined.contains("seven day") {
            return .weekly
        }
        if combined.contains("five") || combined.contains("5h") || combined.contains("5-hour") || combined.contains("5 hour") {
            return .fiveHour
        }
        return .fiveHour
    }

    // MARK: - Language Server Response Parsing (GetUserStatus fallback)

    private func parseLanguageServerResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid response from Antigravity language server")
        }

        let userStatus = json["userStatus"] as? [String: Any] ?? json
        let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any] ?? [:]
        let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] ?? []

        var allModels: [ModelQuotaEntry] = []
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
            allModels.append(ModelQuotaEntry(label: label, remainingFraction: remaining, resetTime: resetStr))
        }

        var groups = buildAntigravityUsageGroups(from: allModels)
        let creditLimits = parseCredits(userStatus)
        if !creditLimits.isEmpty, let first = groups.first {
            groups = [UsageGroup(name: first.name, limits: first.limits + creditLimits)]
        }
        return groups
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
