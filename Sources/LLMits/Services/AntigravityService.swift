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
struct AntigravityService: UsageService {
    var cachedServers: [AntigravityServerInfo] = []

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        debugLog("[Antigravity] fetchUsage with \(cachedServers.count) cached servers")

        for (i, server) in cachedServers.enumerated() {
            guard let ep = server.extensionPort else { continue }
            let portsToTry = [ep + 1, ep + 2, ep, ep + 3]

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

        var groups: [UsageGroup] = []

        for config in configs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any],
                  let remaining = quotaInfo["remainingFraction"] as? Double ?? quotaInfo["remaining_fraction"] as? Double else {
                continue
            }

            let label = config["label"] as? String ?? config["modelLabel"] as? String ?? "Unknown"
            let resetStr = quotaInfo["resetTime"] as? String ?? quotaInfo["reset_time"] as? String

            // Use shared stale-reset detection
            let (adjustedUsed, resetDetail) = TimeFormatter.adjustForStaleReset(
                percentUsed: 1.0 - remaining,
                resetDateString: resetStr,
                windowSeconds: TimeFormatter.fiveHourSeconds
            )

            groups.append(UsageGroup(name: categorizeModel(label), limits: [
                UsageLimit(name: label, percentUsed: adjustedUsed, detail: resetDetail, windowType: .fiveHour)
            ]))
        }

        if groups.isEmpty {
            let email = userStatus["email"] as? String ?? "Connected"
            groups.append(UsageGroup(name: "Antigravity", limits: [
                UsageLimit(name: email, percentUsed: 0, detail: "No quota data", windowType: .unknown)
            ]))
        }

        return groups
    }

    private func categorizeModel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("opus") { return "Claude Opus" }
        if lower.contains("sonnet") { return "Claude Sonnet" }
        if lower.contains("claude") { return "Claude" }
        if lower.contains("3.1 pro") { return "Gemini 3.1 Pro" }
        if lower.contains("pro") { return "Gemini Pro" }
        if lower.contains("flash") { return "Gemini Flash" }
        if lower.contains("gpt") { return "GPT" }
        return label
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
