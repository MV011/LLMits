import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
/// Reads credentials from macOS Keychain (Claude Code CLI) or ~/.claude/.credentials.json.
struct AnthropicService: UsageService {
    private static let providerKey = "anthropic"
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        // Shared rate-limit backoff
        if RateLimiter.shared.isLimited(Self.providerKey) {
            let remaining = RateLimiter.shared.remainingSeconds(Self.providerKey)
            debugLog("[Anthropic] backing off, rate limited for \(remaining)s more")
            throw ServiceError.httpError(429)
        }

        let accessToken = try await resolveAccessToken(manualToken: token)
        let (data, httpResponse) = try await makeRequest(accessToken: accessToken)

        switch httpResponse.statusCode {
        case 200:
            RateLimiter.shared.clear(Self.providerKey)
            return try parseUsageResponse(data)
        case 401:
            debugLog("[Anthropic] got 401, invalidating cache for next refresh")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.remove("\(Self.providerKey)_creds")
            throw ServiceError.httpError(401)
        case 429:
            debugLog("[Anthropic] got 429, backing off")
            RateLimiter.shared.recordLimit(Self.providerKey)
            throw ServiceError.httpError(429)
        default:
            throw ServiceError.httpError(httpResponse.statusCode)
        }
    }

    // MARK: - Networking

    private func makeRequest(accessToken: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }
        return (data, httpResponse)
    }

    // MARK: - Token Resolution

    private struct OAuthCredentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double  // epoch milliseconds
    }

    private func resolveAccessToken(manualToken: String) async throws -> String {
        if manualToken != "mock-token" && !manualToken.isEmpty {
            return manualToken
        }

        // Check in-memory cache first (avoids Keychain prompts)
        if let cached: OAuthCredentials = TokenCache.shared.getObject("\(Self.providerKey)_creds") {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if cached.expiresAt > nowMs + 60_000 {
                return cached.accessToken
            }
            debugLog("[Anthropic] cached token expired, refreshing...")
            if let refreshed = try? await refreshAccessToken(refreshToken: cached.refreshToken) {
                return refreshed
            }
            debugLog("[Anthropic] refresh failed, will re-read credentials")
            TokenCache.shared.remove("\(Self.providerKey)_creds")
            TokenCache.shared.remove(Self.providerKey)
        }

        // First access or cache cleared — read from Keychain/file (may trigger one prompt)
        guard let creds = Self.loadCredentials() else {
            throw ServiceError.noCredentials("Install Claude Code CLI and run 'claude' to login, or paste an OAuth token manually.")
        }

        // Cache in memory for subsequent calls
        TokenCache.shared.setObject("\(Self.providerKey)_creds", value: creds)

        let nowMs = Date().timeIntervalSince1970 * 1000
        if creds.expiresAt > nowMs + 60_000 {
            TokenCache.shared.set(Self.providerKey, value: creds.accessToken)
            return creds.accessToken
        }

        // Token already expired — try to refresh
        debugLog("[Anthropic] token from credentials already expired, refreshing...")
        if let refreshed = try? await refreshAccessToken(refreshToken: creds.refreshToken) {
            return refreshed
        }

        debugLog("[Anthropic] refresh failed, trying expired token")
        return creds.accessToken
    }

    // MARK: - Credentials Loading

    private static func loadCredentials() -> OAuthCredentials? {
        // Try Keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let jsonStr = String(data: data, encoding: .utf8),
           let creds = parseOAuthCredentials(jsonStr) {
            return creds
        }

        // Try credentials files
        let home = FileManager.default.homeDirectoryForCurrentUser
        for path in [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude/credentials.json"),
        ] {
            if let data = try? Data(contentsOf: path),
               let jsonStr = String(data: data, encoding: .utf8),
               let creds = parseOAuthCredentials(jsonStr) {
                return creds
            }
        }

        return nil
    }

    private static func parseOAuthCredentials(_ json: String) -> OAuthCredentials? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Claude Code stores tokens under "claudeAiOauth"
        let source = (obj["claudeAiOauth"] as? [String: Any]) ?? obj

        guard let access = source["accessToken"] as? String ?? source["access_token"] as? String else {
            return nil
        }

        let refresh = source["refreshToken"] as? String ?? source["refresh_token"] as? String ?? ""
        let expires = source["expiresAt"] as? Double ?? 0
        return OAuthCredentials(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        guard !refreshToken.isEmpty else {
            throw ServiceError.noCredentials("No refresh token available")
        }

        let url = URL(string: "https://console.anthropic.com/v1/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ServiceError.httpError(code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["access_token"] as? String else {
            throw ServiceError.parseError("Invalid refresh response")
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let newExpiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

        // Update in-memory cache
        TokenCache.shared.set(Self.providerKey, value: newAccessToken)
        TokenCache.shared.setObject("\(Self.providerKey)_creds", value: OAuthCredentials(
            accessToken: newAccessToken, refreshToken: newRefreshToken, expiresAt: newExpiresAt
        ))

        // Update Keychain in background
        Self.updateKeychainTokens(accessToken: newAccessToken, refreshToken: newRefreshToken, expiresAt: newExpiresAt)
        debugLog("[Anthropic] token refreshed successfully")

        return newAccessToken
    }

    private static func updateKeychainTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let jsonStr = String(data: data, encoding: .utf8),
              let jsonData = jsonStr.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        if var claudeOAuth = obj["claudeAiOauth"] as? [String: Any] {
            claudeOAuth["accessToken"] = accessToken
            claudeOAuth["refreshToken"] = refreshToken
            claudeOAuth["expiresAt"] = expiresAt
            obj["claudeAiOauth"] = claudeOAuth
        }

        guard let updatedData = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemUpdate(updateQuery as CFDictionary, [kSecValueData as String: updatedData] as CFDictionary)
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        let windows: [(key: String, name: String, type: UsageLimit.WindowType)] = [
            ("five_hour", "5-Hour Session", .fiveHour),
            ("seven_day", "Weekly Overall", .weekly),
            ("seven_day_opus", "Weekly — Opus", .weekly),
            ("seven_day_sonnet", "Weekly — Sonnet", .weekly),
        ]

        for (key, name, windowType) in windows {
            if let window = json[key] as? [String: Any],
               let limit = parseWindow(window, name: name, windowType: windowType) {
                groups.append(UsageGroup(name: name, limits: [limit]))
            }
        }

        // Parse extra_usage (spend) — API returns values in cents
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let spentCents = extra["used_credits"] as? Double ?? extra["spend"] as? Double ?? 0
            let limitCents = extra["monthly_limit"] as? Double ?? extra["limit"] as? Double ?? 0
            let spent = spentCents / 100.0
            let limit = limitCents / 100.0
            if limit > 0 {
                let pct: Double
                if let u = extra["utilization"] as? Double {
                    pct = min((u > 1.0 ? u / 100.0 : u), 1.0)
                } else {
                    pct = min(spent / limit, 1.0)
                }
                groups.append(UsageGroup(name: "Extra Usage", limits: [
                    UsageLimit(name: "Monthly Spend", percentUsed: pct,
                               detail: String(format: "$%.2f / $%.2f", spent, limit),
                               windowType: .monthly)
                ]))
            }
        }

        if groups.isEmpty {
            groups.append(UsageGroup(name: "Claude Usage", limits: [
                UsageLimit(name: "Connected", percentUsed: 0, detail: "No usage data available", windowType: .unknown)
            ]))
        }

        return groups
    }

    private func parseWindow(_ window: [String: Any], name: String, windowType: UsageLimit.WindowType) -> UsageLimit? {
        let resetStr = (window["resets_at"] ?? window["reset_at"] ?? window["resetAt"]) as? String

        let windowSeconds: Double = (windowType == .weekly) ? TimeFormatter.weeklySeconds : TimeFormatter.fiveHourSeconds

        // Try "utilization" field
        if let utilization = window["utilization"] as? Double {
            let normalized = utilization > 1.0 ? utilization / 100.0 : utilization
            let (adjusted, detail) = TimeFormatter.adjustForStaleReset(
                percentUsed: normalized, resetDateString: resetStr, windowSeconds: windowSeconds
            )
            return UsageLimit(name: name, percentUsed: adjusted, detail: detail, windowType: windowType)
        }

        // Try "percent_used" / "percentUsed"
        if let pctUsed = window["percent_used"] as? Double ?? window["percentUsed"] as? Double {
            let (adjusted, detail) = TimeFormatter.adjustForStaleReset(
                percentUsed: pctUsed / 100.0, resetDateString: resetStr, windowSeconds: windowSeconds
            )
            return UsageLimit(name: name, percentUsed: adjusted, detail: detail, windowType: windowType)
        }

        return nil
    }
}
