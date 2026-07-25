import Foundation

/// Fetches OpenAI Codex / ChatGPT usage via OAuth tokens from the Codex CLI.
struct OpenAIService: UsageService {
    private static let providerKey = "openai"
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        var accessToken = try await resolveAccessToken(manualToken: token)

        do {
            var request = URLRequest(url: usageURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                RateLimiter.shared.clear(Self.providerKey)
                return try parseUsageResponse(data)
            case 401, 403:
                throw ServiceError.noCredentials("Codex credentials expired or invalid.")
            case 429:
                let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
                let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
                RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
                throw ServiceError.httpError(429)
            default:
                throw ServiceError.httpError(httpResponse.statusCode)
            }
        } catch ServiceError.noCredentials(let message) {
            // A pasted manual token can't be refreshed — retrying would just
            // re-send the identical token, guaranteed to fail.
            if token != "mock-token" && token != "mock" && !token.isEmpty {
                throw ServiceError.noCredentials(message)
            }

            // Token might be stale — retry ONCE with fresh read from auth.json
            debugLog("[OpenAI] got auth error, retrying with fresh credentials")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")

            accessToken = try await resolveAccessToken(manualToken: token, forceFresh: true)

            var request = URLRequest(url: usageURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServiceError.invalidResponse
            }

            if httpResponse.statusCode == 200 {
                RateLimiter.shared.clear(Self.providerKey)
                return try parseUsageResponse(data)
            } else if httpResponse.statusCode == 429 {
                let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
                let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
                RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
                throw ServiceError.httpError(429)
            } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                // Retry failed the same way — keep the actionable message
                throw ServiceError.noCredentials(message)
            } else {
                throw ServiceError.httpError(httpResponse.statusCode)
            }
        }
    }

    // MARK: - Token Resolution

    private func resolveAccessToken(manualToken: String, forceFresh: Bool = false) async throws -> String {
        if manualToken != "mock-token" && manualToken != "mock" && !manualToken.isEmpty {
            return manualToken
        }

        if !forceFresh {
            if let cached = TokenCache.shared.get(Self.providerKey) {
                if let exp: Date = TokenCache.shared.getObject(Self.providerKey + ".expiresAt") {
                    let buffer: TimeInterval = 5 * 60  // 5 minutes safety margin
                    if exp.timeIntervalSinceNow > buffer {
                        return cached
                    }
                    debugLog("[OpenAI] cached token expiring soon (at \(exp)), will re-read auth.json")
                    // fall through to fresh read from file
                } else {
                    return cached
                }
            }
        }

        if let token = loadFromAuthJSON() {
            TokenCache.shared.set(Self.providerKey, value: token)
            if let exp = JWT.expiry(token) {
                TokenCache.shared.setObject(Self.providerKey + ".expiresAt", value: exp)
            } else {
                TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")
            }
            return token
        }

        throw ServiceError.noCredentials("Install Codex CLI and login, or paste an access token manually.")
    }

    private func loadFromAuthJSON() -> String? {
        guard let json = Self.readAuthJSON() else { return nil }

        if let tokens = json["tokens"] as? [String: Any],
           let token = tokens["access_token"] as? String ?? tokens["accessToken"] as? String {
            return token
        }
        if let token = json["access_token"] as? String ?? json["accessToken"] as? String {
            return token
        }
        return nil
    }

    /// The email of the account Codex CLI is logged into, decoded locally from
    /// the id_token (or access token profile claim) in auth.json. No network.
    func currentIdentity() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                guard let json = Self.readAuthJSON(),
                      let tokens = json["tokens"] as? [String: Any] else {
                    cont.resume(returning: nil)
                    return
                }
                if let idToken = tokens["id_token"] as? String,
                   let email = JWT.payload(idToken)?["email"] as? String {
                    cont.resume(returning: email)
                    return
                }
                if let access = tokens["access_token"] as? String,
                   let profile = JWT.payload(access)?["https://api.openai.com/profile"] as? [String: Any],
                   let email = profile["email"] as? String {
                    cont.resume(returning: email)
                    return
                }
                cont.resume(returning: nil)
            }
        }
    }

    private static func readAuthJSON() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [URL]()
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json"))
        }
        paths.append(home.appendingPathComponent(".codex/auth.json"))

        for path in paths {
            if let data = try? Data(contentsOf: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
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

        // Main rate limit
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            groups += parseRateLimitBlock(rateLimit, namePrefix: "Codex")
        }

        // Additional rate limits (Spark, etc.)
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for entry in additional {
                let name = entry["limit_name"] as? String ?? "Unknown"
                if let rl = entry["rate_limit"] as? [String: Any] {
                    groups += parseRateLimitBlock(rl, namePrefix: name)
                }
            }
        }

        // Code review rate limit
        if let codeReview = json["code_review_rate_limit"] as? [String: Any] {
            if let limit = parseRateWindow(codeReview["primary_window"] as? [String: Any],
                                           name: "Code Review", windowType: .unknown) {
                groups.append(UsageGroup(name: "Code Review", limits: [limit]))
            }
        }

        // Credits / balance
        if let credits = json["credits"] as? [String: Any] {
            groups.append(parseCredits(credits))
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

    /// Parses a rate_limit block with primary + secondary windows.
    private func parseRateLimitBlock(_ block: [String: Any], namePrefix: String) -> [UsageGroup] {
        var groups: [UsageGroup] = []

        if let limit = parseRateWindow(block["primary_window"] as? [String: Any],
                                       name: "\(namePrefix) 5h Limit", windowType: .fiveHour) {
            groups.append(UsageGroup(name: "\(namePrefix) — 5h", limits: [limit]))
        }

        if let limit = parseRateWindow(block["secondary_window"] as? [String: Any],
                                       name: "\(namePrefix) Weekly", windowType: .weekly) {
            groups.append(UsageGroup(name: "\(namePrefix) — Weekly", limits: [limit]))
        }

        return groups
    }

    /// Parses a single rate window (primary or secondary) into a UsageLimit.
    private func parseRateWindow(_ window: [String: Any]?, name: String, windowType: UsageLimit.WindowType) -> UsageLimit? {
        guard let window else { return nil }

        let usedPct = window["used_percent"] as? Double ?? 0
        let resetText = TimeFormatter.formatResetTime(
            epochOrSeconds: window["reset_at"] as? Double ?? window["reset_after_seconds"] as? Double,
            isEpoch: window["reset_at"] != nil
        )

        return UsageLimit(
            name: name,
            percentUsed: min(usedPct / 100.0, 1.0),
            detail: resetText,
            windowType: windowType
        )
    }

    /// Parses the credits/balance section.
    private func parseCredits(_ credits: [String: Any]) -> UsageGroup {
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

        return UsageGroup(name: "Credits", limits: [
            UsageLimit(name: "Credit Balance",
                       percentUsed: (unlimited || balance > 0) ? 0 : 1.0,
                       detail: detail, windowType: .monthly)
        ])
    }
}
