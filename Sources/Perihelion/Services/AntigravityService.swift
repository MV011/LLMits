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

    // CRITICAL: Read the pipe BEFORE waitUntilExit().
    // If ps output exceeds the pipe buffer (64KB), ps blocks on write
    // while waitUntilExit() blocks waiting for ps to exit = deadlock.
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
    /// Pre-resolved servers — set by the caller BEFORE entering a task group.
    var cachedServers: [AntigravityServerInfo] = []

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        debugLog("[Antigravity] fetchUsage with \(cachedServers.count) cached servers")

        for (i, server) in cachedServers.enumerated() {
            let portsToTry: [Int]
            if let ep = server.extensionPort {
                portsToTry = [ep + 1, ep + 2, ep, ep + 3]
            } else {
                continue
            }

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

        let session = Self._insecureSession
        let (data, response) = try await session.data(for: request)

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

        var groups: [UsageGroup] = []

        let userStatus = json["userStatus"] as? [String: Any] ?? json
        let cascadeData = userStatus["cascadeModelConfigData"] as? [String: Any] ?? [:]
        let configs = cascadeData["clientModelConfigs"] as? [[String: Any]] ?? []

        for config in configs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any] else { continue }
            let remaining = quotaInfo["remainingFraction"] as? Double ?? quotaInfo["remaining_fraction"] as? Double
            guard let rem = remaining else { continue }

            let label = config["label"] as? String ?? config["modelLabel"] as? String ?? "Unknown"
            let resetStr = quotaInfo["resetTime"] as? String ?? quotaInfo["reset_time"] as? String

            // Check if the reset time is in the past — if so, the quota has reset
            // and remainingFraction may be stale (0 = "starts on next message", not "exhausted")
            var effectiveUsed = 1.0 - rem
            var resetDetail: String? = nil
            if let rs = resetStr {
                let f1 = ISO8601DateFormatter()
                f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let resetDate = f1.date(from: rs) ?? ISO8601DateFormatter().date(from: rs)
                if let rd = resetDate {
                    if rd.timeIntervalSinceNow <= 0 {
                        // Reset time passed — quota is fresh, treat as 0% used
                        effectiveUsed = 0
                        resetDetail = nil
                    } else {
                        resetDetail = TimeFormatter.formatRemaining(rd.timeIntervalSinceNow)
                    }
                }
            }

            groups.append(UsageGroup(name: categorizeModel(label), limits: [
                UsageLimit(name: label, percentUsed: effectiveUsed, detail: resetDetail, windowType: .fiveHour)
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

    // MARK: - TLS

    private static let _insecureSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }()
}

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

/// File-based debug logger that works for GUI apps.
func debugLog(_ msg: String) {
    let line = "\(Date()): \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: "/tmp/llmits_debug.log") {
            if let fh = FileHandle(forWritingAtPath: "/tmp/llmits_debug.log") {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: "/tmp/llmits_debug.log", contents: data)
        }
    }
}
