import Foundation

/// Fetches OpenAI Codex / ChatGPT usage via OAuth tokens from the Codex CLI.
struct OpenAIService: UsageService {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        let accessToken = try resolveAccessToken(manualToken: token)

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw ServiceError.httpError(httpResponse.statusCode)
        }

        return try parseUsageResponse(data)
    }

    // MARK: - Token Resolution

    private func resolveAccessToken(manualToken: String) throws -> String {
        if manualToken != "mock-token" && !manualToken.isEmpty {
            return manualToken
        }

        if let cached = TokenCache.shared.get("openai") {
            return cached
        }

        if let token = loadFromAuthJSON() {
            TokenCache.shared.set("openai", value: token)
            return token
        }

        throw ServiceError.noCredentials("Install Codex CLI and login, or paste an access token manually.")
    }

    private func loadFromAuthJSON() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [URL]()
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        paths.append(home.appendingPathComponent(".codex/auth.json"))

        for path in paths {
            guard let data = try? Data(contentsOf: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let tokens = json["tokens"] as? [String: Any],
               let token = tokens["access_token"] as? String ?? tokens["accessToken"] as? String {
                return token
            }

            if let token = json["access_token"] as? String ?? json["accessToken"] as? String {
                return token
            }
        }
        return nil
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        // Parse rate_limit structure (actual Codex API format)
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                let usedPct = primary["used_percent"] as? Double ?? 0
                let resetText = TimeFormatter.formatResetTime(
                    epochOrSeconds: primary["reset_at"] as? Double ?? primary["reset_after_seconds"] as? Double,
                    isEpoch: primary["reset_at"] != nil)

                groups.append(UsageGroup(name: "5-Hour Session", limits: [
                    UsageLimit(name: "Codex 5h Limit", percentUsed: min(usedPct / 100.0, 1.0),
                               detail: resetText, windowType: .fiveHour)
                ]))
            }

            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                let usedPct = secondary["used_percent"] as? Double ?? 0
                let resetText = TimeFormatter.formatResetTime(
                    epochOrSeconds: secondary["reset_at"] as? Double ?? secondary["reset_after_seconds"] as? Double,
                    isEpoch: secondary["reset_at"] != nil)

                groups.append(UsageGroup(name: "Weekly", limits: [
                    UsageLimit(name: "Codex Weekly", percentUsed: min(usedPct / 100.0, 1.0),
                               detail: resetText, windowType: .weekly)
                ]))
            }
        }

        // Additional rate limits (Spark, etc.)
        if let additionalLimits = json["additional_rate_limits"] as? [[String: Any]] {
            for additionalLimit in additionalLimits {
                let limitName = additionalLimit["limit_name"] as? String ?? "Unknown"
                guard let rl = additionalLimit["rate_limit"] as? [String: Any] else { continue }

                if let primary = rl["primary_window"] as? [String: Any] {
                    let usedPct = primary["used_percent"] as? Double ?? 0
                    let resetText = TimeFormatter.formatResetTime(
                        epochOrSeconds: primary["reset_at"] as? Double ?? primary["reset_after_seconds"] as? Double,
                        isEpoch: primary["reset_at"] != nil)

                    groups.append(UsageGroup(name: "\(limitName) — 5h", limits: [
                        UsageLimit(name: limitName, percentUsed: min(usedPct / 100.0, 1.0),
                                   detail: resetText, windowType: .fiveHour)
                    ]))
                }

                if let secondary = rl["secondary_window"] as? [String: Any] {
                    let usedPct = secondary["used_percent"] as? Double ?? 0
                    let resetText = TimeFormatter.formatResetTime(
                        epochOrSeconds: secondary["reset_at"] as? Double ?? secondary["reset_after_seconds"] as? Double,
                        isEpoch: secondary["reset_at"] != nil)

                    groups.append(UsageGroup(name: "\(limitName) — Weekly", limits: [
                        UsageLimit(name: "\(limitName) Weekly", percentUsed: min(usedPct / 100.0, 1.0),
                                   detail: resetText, windowType: .weekly)
                    ]))
                }
            }
        }

        // Code review rate limit
        if let codeReview = json["code_review_rate_limit"] as? [String: Any] {
            if let primary = codeReview["primary_window"] as? [String: Any] {
                let usedPct = primary["used_percent"] as? Double ?? 0
                let resetText = TimeFormatter.formatResetTime(
                    epochOrSeconds: primary["reset_at"] as? Double ?? primary["reset_after_seconds"] as? Double,
                    isEpoch: primary["reset_at"] != nil)

                groups.append(UsageGroup(name: "Code Review", limits: [
                    UsageLimit(name: "Code Review", percentUsed: min(usedPct / 100.0, 1.0),
                               detail: resetText, windowType: .unknown)
                ]))
            }
        }

        // Credits / balance
        if let credits = json["credits"] as? [String: Any] {
            let balanceStr = credits["balance"] as? String ?? "0"
            let balance = Double(balanceStr) ?? 0
            let hasCredits = credits["has_credits"] as? Bool ?? false
            let unlimited = credits["unlimited"] as? Bool ?? false

            let detail: String
            if unlimited {
                detail = "Unlimited"
            } else if hasCredits || balance > 0 {
                detail = String(format: "$%.2f remaining", balance)
            } else {
                detail = "$0.00 remaining"
            }

            groups.append(UsageGroup(name: "Credits", limits: [
                UsageLimit(
                    name: "Credit Balance",
                    percentUsed: (unlimited || balance > 0) ? 0 : 1.0,
                    detail: detail,
                    windowType: .monthly
                )
            ]))
        }

        if groups.isEmpty {
            let planType = json["plan_type"] as? String ?? "unknown"
            groups.append(UsageGroup(name: "Codex (\(planType))", limits: [
                UsageLimit(name: "Connected", percentUsed: 0,
                           detail: json["email"] as? String ?? "No usage data", windowType: .unknown)
            ]))
        }

        return groups
    }
}
