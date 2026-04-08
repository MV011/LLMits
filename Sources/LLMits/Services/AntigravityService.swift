import Foundation

/// Pre-resolved Antigravity server info (discovered BEFORE entering async task groups).
struct AntigravityServerInfo: Sendable {
    let pid: String
    let csrfToken: String
    let extensionPort: Int?
}

/// Discovers Antigravity language servers. MUST be called outside of
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
        guard trimmed.contains("language_server_macos") && trimmed.contains("antigravity") else {
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

/// Fetches Antigravity quota by probing the local language server process.
/// Groups the 5-6 individual models into 3 buckets:
///   1. Gemini Pro — Gemini 3.1 Pro (High) + Gemini 3.1 Pro (Low)
///   2. Gemini Flash — Gemini 3 Flash
///   3. Cloud — Claude Opus, Claude Sonnet, GPT-OSS (shared quota)
/// Also surfaces AI credit balances.
struct AntigravityService: UsageService {
    var cachedServers: [AntigravityServerInfo] = []

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        debugLog("[Antigravity] fetchUsage with \(cachedServers.count) cached servers")

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
            throw ServiceError.processNotFound("Antigravity is not running. Launch it to see usage data.")
        }
        throw ServiceError.processNotFound("Antigravity is running but could not connect to language server.")
    }

    // MARK: - Quota Fetch

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

        return try parseQuotaResponse(data)
    }

    // MARK: - Response Parsing

    private func parseQuotaResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid response from Antigravity language server")
        }

        let userStatus = json["userStatus"] as? [String: Any] ?? json
        let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any] ?? [:]
        let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] ?? []

        // 1. Collect all models with quota info
        struct ModelQuota {
            let label: String
            let remainingFraction: Double
            let resetTime: String?
        }

        var allModels: [ModelQuota] = []
        for config in configs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any] else {
                continue
            }
            // Handle both Double (0.2) and Int (1) JSON values
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

        // 2. Group into 3 buckets
        //    Models within each bucket share the same remaining fraction and reset time
        var geminiPro: [ModelQuota] = []
        var geminiFlash: [ModelQuota] = []
        var cloud: [ModelQuota] = []

        for model in allModels {
            let bucket = classifyIntoBucket(model.label)
            switch bucket {
            case .geminiPro: geminiPro.append(model)
            case .geminiFlash: geminiFlash.append(model)
            case .cloud: cloud.append(model)
            }
        }

        // 3. Build limits from the 3 buckets
        var limits: [UsageLimit] = []

        if let rep = geminiPro.first {
            limits.append(buildBucketLimit(
                name: "Gemini Pro",
                models: geminiPro.map(\.label),
                remainingFraction: rep.remainingFraction,
                resetTime: rep.resetTime
            ))
        }

        if let rep = geminiFlash.first {
            limits.append(buildBucketLimit(
                name: "Gemini Flash",
                models: geminiFlash.map(\.label),
                remainingFraction: rep.remainingFraction,
                resetTime: rep.resetTime
            ))
        }

        if let rep = cloud.first {
            limits.append(buildBucketLimit(
                name: "Cloud",
                models: cloud.map(\.label),
                remainingFraction: rep.remainingFraction,
                resetTime: rep.resetTime
            ))
        }

        // 4. Add credits info
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

    // MARK: - Bucketing

    private enum Bucket {
        case geminiPro, geminiFlash, cloud
    }

    private func classifyIntoBucket(_ label: String) -> Bucket {
        let lower = label.lowercased()
        // Gemini Pro variants (High, Low, etc.)
        if lower.contains("gemini") && lower.contains("pro") {
            return .geminiPro
        }
        // Gemini Flash
        if lower.contains("gemini") && lower.contains("flash") {
            return .geminiFlash
        }
        // Everything else: Claude, GPT-OSS, etc.
        return .cloud
    }

    private func buildBucketLimit(
        name: String,
        models: [String],
        remainingFraction: Double,
        resetTime: String?
    ) -> UsageLimit {
        let (adjustedUsed, resetDetail) = TimeFormatter.adjustForStaleReset(
            percentUsed: 1.0 - remainingFraction,
            resetDateString: resetTime,
            windowSeconds: TimeFormatter.fiveHourSeconds
        )

        // Build models detail
        let modelsStr = models.joined(separator: ", ")
        var detail = modelsStr
        if let rd = resetDetail, !rd.isEmpty {
            detail = "\(modelsStr) · \(rd)"
        }

        return UsageLimit(
            name: name,
            percentUsed: adjustedUsed,
            detail: detail,
            windowType: .fiveHour
        )
    }

    // MARK: - Credits

    private func parseCredits(_ userStatus: [String: Any]) -> [UsageLimit] {
        var credits: [UsageLimit] = []

        // Google One AI credits (from userTier.availableCredits)
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
                        percentUsed: 0, // No total known; display as info-only
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
