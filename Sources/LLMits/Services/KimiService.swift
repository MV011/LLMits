import Foundation

/// Fetches Kimi Code subscription usage via the Kimi coding API.
/// Reads OAuth credentials from ~/.kimi-code/credentials/kimi-code.json
/// (written by the Kimi Code CLI on login).
///
/// We do NOT refresh the OAuth token ourselves — the CLI owns the refresh
/// token and may rotate it, so an external refresh could break the CLI login.
/// On 401/expiry we re-read the file once, then ask the user to run `kimi`.
struct KimiService: UsageService {
    private static let providerKey = "kimi"
    private let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        var accessToken = try await resolveAccessToken(manualToken: token)

        do {
            let (data, httpResponse) = try await makeRequest(accessToken: accessToken)

            switch httpResponse.statusCode {
            case 200:
                RateLimiter.shared.clear(Self.providerKey)
                return try parseUsageResponse(data)
            case 401, 403:
                throw ServiceError.noCredentials("Kimi Code credentials expired or invalid.")
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

            // Token might be stale — retry ONCE with a fresh read of the credentials file
            debugLog("[Kimi] got auth error, retrying with fresh credentials")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")

            accessToken = try await resolveAccessToken(manualToken: token, forceFresh: true)
            let (retryData, retryResponse) = try await makeRequest(accessToken: accessToken)

            if retryResponse.statusCode == 200 {
                RateLimiter.shared.clear(Self.providerKey)
                return try parseUsageResponse(retryData)
            } else if retryResponse.statusCode == 429 {
                let retryAfterStr = retryResponse.value(forHTTPHeaderField: "Retry-After")
                let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
                RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
                throw ServiceError.httpError(429)
            } else if retryResponse.statusCode == 401 || retryResponse.statusCode == 403 {
                // Retry failed the same way — keep the actionable message
                throw ServiceError.noCredentials(message)
            } else {
                throw ServiceError.httpError(retryResponse.statusCode)
            }
        }
    }

    /// The user id the current Kimi credential belongs to, decoded locally from
    /// the access token JWT (`user_id` claim). No network.
    func currentIdentity() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                guard let json = Self.readCredentialsFile(),
                      let token = json["access_token"] as? String else {
                    cont.resume(returning: nil)
                    return
                }
                let payload = JWT.payload(token)
                cont.resume(returning: payload?["user_id"] as? String ?? payload?["sub"] as? String)
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
                    debugLog("[Kimi] cached token expiring soon (at \(exp)), will re-read credentials file")
                    // fall through to fresh read from file
                } else {
                    return cached
                }
            }
        }

        if let (token, expiresAt) = loadFromCredentialsFile() {
            TokenCache.shared.set(Self.providerKey, value: token)
            if let expiresAt {
                TokenCache.shared.setObject(Self.providerKey + ".expiresAt", value: expiresAt)
            } else {
                TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")
            }
            return token
        }

        throw ServiceError.noCredentials("Install Kimi Code CLI and run 'kimi' to login, or paste an access token manually.")
    }

    private func loadFromCredentialsFile() -> (token: String, expiresAt: Date?)? {
        guard let json = Self.readCredentialsFile(),
              let token = json["access_token"] as? String, !token.isEmpty else {
            return nil
        }
        let expiresAt = (json["expires_at"] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return (token, expiresAt)
    }

    private static func readCredentialsFile() -> [String: Any]? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Networking

    private func makeRequest(accessToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return (data, httpResponse)
    }

    // MARK: - Response Parsing

    /// Parses the /usages response. Numeric fields arrive as JSON strings.
    /// Example:
    /// { "usage": {"limit": "100", "remaining": "100", "resetTime": "…"},
    ///   "limits": [{"window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
    ///               "detail": {"limit": "100", "used": "1", "resetTime": "…"}}] }
    private func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        // Rolling rate-limit windows (currently a single 300-minute = 5h window).
        // The API omits zero-valued fields proto3-style — "used" disappears
        // entirely when the window is unused — so derive missing values
        // instead of dropping the group.
        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                guard let detail = entry["detail"] as? [String: Any],
                      let limit = Self.parseNumber(detail["limit"]), limit > 0 else { continue }
                let used = Self.parseNumber(detail["used"])
                    ?? Self.parseNumber(detail["remaining"]).map { max(limit - $0, 0) }
                    ?? 0

                let window = entry["window"] as? [String: Any]
                let windowSeconds = Self.windowDurationSeconds(window)
                let isFiveHour = windowSeconds == nil || abs((windowSeconds ?? 18_000) - 18_000) < 60
                let windowType: UsageLimit.WindowType = isFiveHour ? .fiveHour : .unknown
                let name = isFiveHour ? "Kimi — 5h" : "Kimi — Rate Window"

                let (adjusted, resetDetail) = TimeFormatter.adjustForStaleReset(
                    percentUsed: min(used / limit, 1.0),
                    resetDateString: detail["resetTime"] as? String,
                    windowSeconds: windowSeconds ?? TimeFormatter.fiveHourSeconds
                )
                groups.append(UsageGroup(name: name, limits: [
                    UsageLimit(name: name, percentUsed: adjusted, detail: resetDetail, windowType: windowType)
                ]))
            }
        }

        // Weekly subscription quota (same zero-omission handling: "remaining"
        // disappears at 0, "used" disappears at 0)
        if let usage = json["usage"] as? [String: Any],
           let limit = Self.parseNumber(usage["limit"]), limit > 0 {
            let remaining = Self.parseNumber(usage["remaining"])
                ?? Self.parseNumber(usage["used"]).map { max(limit - $0, 0) }
                ?? 0
            let resetText = (usage["resetTime"] as? String)
                .flatMap(TimeFormatter.formatResetTime(isoString:))
            groups.append(UsageGroup(name: "Kimi — Weekly", limits: [
                UsageLimit(name: "Kimi — Weekly",
                           percentUsed: min(max((limit - remaining) / limit, 0), 1),
                           detail: resetText,
                           windowType: .weekly)
            ]))
        }

        if groups.isEmpty {
            let level = ((json["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
            groups.append(UsageGroup(name: "Kimi Code", limits: [
                UsageLimit(name: "Connected", percentUsed: 0,
                           detail: level.map { Self.membershipName($0) } ?? "No usage data",
                           windowType: .unknown)
            ]))
        }

        return groups
    }

    /// "100" / 100 / 100.0 → 100 (API mixes JSON strings and numbers)
    private static func parseNumber(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func windowDurationSeconds(_ window: [String: Any]?) -> TimeInterval? {
        guard let window, let duration = parseNumber(window["duration"]) else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3600
        case "TIME_UNIT_DAY": return duration * 86_400
        case "TIME_UNIT_SECOND": return duration
        default: return nil
        }
    }

    /// "LEVEL_STANDARD" → "Standard"
    private static func membershipName(_ level: String) -> String {
        level.replacingOccurrences(of: "LEVEL_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
