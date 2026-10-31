import Foundation

/// Fetches OpenAI Codex / ChatGPT usage via OAuth tokens from the Codex CLI.
struct OpenAIService: UsageService {
    private static let providerKey = "openai"

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        var accessToken = try await resolveAccessToken(manualToken: token)

        do {
            let request = usageRequest(accessToken: accessToken)

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

            let request = usageRequest(accessToken: accessToken)

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

    private func usageRequest(accessToken: String) -> URLRequest {
        Self.usageRequest(
            accessToken: accessToken,
            accountID: Self.accountID(for: accessToken, authJSON: Self.readAuthJSON())
        )
    }

    static func usageRequest(accessToken: String, accountID: String?) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        return request
    }

    /// Keep the routing hint paired with the selected token, including manual
    /// tokens and cached credentials from before a CLI account switch.
    static func accountID(for accessToken: String, authJSON: [String: Any]?) -> String? {
        let tokens = authJSON?["tokens"] as? [String: Any] ?? authJSON
        if let storedToken = tokens?["access_token"] as? String ?? tokens?["accessToken"] as? String,
           storedToken == accessToken,
           let accountID = tokens?["account_id"] as? String,
           !accountID.isEmpty {
            return accountID
        }
        let auth = JWT.payload(accessToken)?["https://api.openai.com/auth"] as? [String: Any]
        guard let accountID = auth?["chatgpt_account_id"] as? String, !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

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

    func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        // Main rate limit
        if let rateLimit = json["rate_limit"] as? [String: Any] {
            groups += try parseRateLimitBlock(rateLimit, namePrefix: "Codex")
        }

        // Additional rate limits (Spark, etc.)
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for entry in additional {
                let name = entry["limit_name"] as? String ?? "Unknown"
                if let rl = entry["rate_limit"] as? [String: Any] {
                    groups += try parseRateLimitBlock(rl, namePrefix: name)
                }
            }
        }

        // Code review rate limit
        if let codeReview = json["code_review_rate_limit"] as? [String: Any] {
            if let limit = try parseRateWindow(codeReview["primary_window"] as? [String: Any],
                                           name: "Code Review", windowType: .unknown) {
                groups.append(UsageGroup(name: "Code Review", limits: [limit]))
            }
        }

        // Credits / balance
        if let credits = json["credits"] as? [String: Any], let group = parseCredits(credits) {
            groups.append(group)
        }

        if groups.isEmpty {
            throw ServiceError.parseError("No usage data in OpenAI response")
        }

        return groups
    }

    /// Parses a rate_limit block with primary + secondary windows.
    private func parseRateLimitBlock(_ block: [String: Any], namePrefix: String) throws -> [UsageGroup] {
        var groups: [UsageGroup] = []

        for (key, fallback) in [("primary_window", UsageLimit.WindowType.fiveHour),
                                ("secondary_window", UsageLimit.WindowType.weekly)] {
            guard let window = block[key] as? [String: Any] else { continue }
            let type: UsageLimit.WindowType
            if let seconds = JSONNumber.double(from: window["limit_window_seconds"]) {
                switch seconds {
                case TimeFormatter.fiveHourSeconds: type = .fiveHour
                case TimeFormatter.weeklySeconds: type = .weekly
                case 86400: type = .daily
                default: type = .unknown
                }
            } else {
                type = fallback
            }
            let label: String
            switch type {
            case .fiveHour: label = "5h"
            case .unknown: label = key == "primary_window" ? "Primary" : "Secondary"
            default: label = type.rawValue
            }
            let limitName = type == .fiveHour ? "\(namePrefix) 5h Limit" : "\(namePrefix) \(label)"
            if let limit = try parseRateWindow(window, name: limitName, windowType: type) {
                groups.append(UsageGroup(name: "\(namePrefix) — \(label)", limits: [limit]))
            }
        }

        return groups
    }

    /// Parses a single rate window (primary or secondary) into a UsageLimit.
    private func parseRateWindow(_ window: [String: Any]?, name: String, windowType: UsageLimit.WindowType) throws -> UsageLimit? {
        guard let window else { return nil }

        guard let usedPct = JSONNumber.double(from: window["used_percent"]), usedPct.isFinite else {
            throw ServiceError.parseError("Missing or invalid OpenAI usage percentage")
        }
        let epoch = JSONNumber.double(from: window["reset_at"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let seconds = JSONNumber.double(from: window["reset_after_seconds"]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let resetAt = TimeFormatter.parseResetDate(
            epochOrSeconds: epoch ?? seconds,
            isEpoch: epoch != nil
        )

        return UsageLimit(
            name: name,
            percentUsed: min(max(usedPct / 100.0, 0), 1.0),
            resetAt: resetAt,
            windowType: windowType
        )
    }

    /// Parses the credits/balance section.
    private func parseCredits(_ credits: [String: Any]) -> UsageGroup? {
        let balance = JSONNumber.double(from: credits["balance"])
        let unlimited = credits["unlimited"] as? Bool ?? false

        let detail: String
        if unlimited {
            detail = "Unlimited"
        } else if let balance, balance.isFinite, balance >= 0 {
            detail = String(format: "Balance: %g", balance)
        } else {
            return nil
        }

        return UsageGroup(name: "Credits", limits: [
            UsageLimit(name: "Credit Balance",
                       percentUsed: 0,
                       detail: detail, windowType: .unknown, percentDisplay: .none)
        ])
    }
}
