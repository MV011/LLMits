import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
/// Reads credentials from macOS Keychain (Claude Code CLI) or ~/.claude/.credentials.json.
struct AnthropicService: UsageService {
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Tracks when we last got rate-limited to back off.
    private static var rateLimitedUntil: Date?

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        // Back off if we recently got rate-limited
        if let until = Self.rateLimitedUntil, until.timeIntervalSinceNow > 0 {
            debugLog("[Anthropic] backing off, rate limited for \(Int(until.timeIntervalSinceNow))s more")
            throw ServiceError.httpError(429)
        }

        let accessToken = try await resolveAccessToken(manualToken: token)
        let (data, httpResponse) = try await makeUsageRequest(accessToken: accessToken)

        switch httpResponse.statusCode {
        case 200:
            return try parseUsageResponse(data)
        case 401:
            // Token expired — invalidate cache so next refresh gets a fresh one
            debugLog("[Anthropic] got 401, invalidating cache for next refresh")
            TokenCache.shared.remove("anthropic")
            TokenCache.shared.remove("anthropic_creds")
            throw ServiceError.httpError(401)
        case 429:
            // Rate limited — back off for 60 seconds
            debugLog("[Anthropic] got 429, backing off for 60s")
            Self.rateLimitedUntil = Date().addingTimeInterval(60)
            throw ServiceError.httpError(429)
        default:
            throw ServiceError.httpError(httpResponse.statusCode)
        }
    }

    private func makeUsageRequest(accessToken: String) async throws -> (Data, HTTPURLResponse) {
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
    private func resolveAccessToken(manualToken: String) async throws -> String {
        // If user pasted a token manually, use it
        if manualToken != "mock-token" && !manualToken.isEmpty {
            return manualToken
        }

        // Check in-memory cache first (avoids Keychain prompts on every refresh)
        if let cached: CachedCredentials = TokenCache.shared.getObject("anthropic_creds") {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if cached.expiresAt > nowMs + 60_000 {
                return cached.accessToken
            }
            // Token expired — try to refresh using cached refresh token
            debugLog("[Anthropic] cached token expired, refreshing...")
            if let refreshed = try? await refreshAccessToken(refreshToken: cached.refreshToken) {
                debugLog("[Anthropic] refresh succeeded")
                return refreshed
            }
            // Refresh failed — clear cache and fall through to Keychain re-read
            debugLog("[Anthropic] refresh failed, will re-read Keychain")
            TokenCache.shared.remove("anthropic_creds")
            TokenCache.shared.remove("anthropic")
        }

        // First access or cache cleared — read from Keychain (triggers one prompt)
        guard let creds = Self.loadCredentials() else {
            throw ServiceError.noCredentials("Install Claude Code CLI and run 'claude' to login, or paste an OAuth token manually.")
        }

        // Cache the full credentials in memory for subsequent calls
        TokenCache.shared.setObject("anthropic_creds", value: CachedCredentials(
            accessToken: creds.accessToken,
            refreshToken: creds.refreshToken,
            expiresAt: creds.expiresAt
        ))

        let nowMs = Date().timeIntervalSince1970 * 1000
        if creds.expiresAt > nowMs + 60_000 {
            TokenCache.shared.set("anthropic", value: creds.accessToken)
            return creds.accessToken
        }

        // Token already expired — try to refresh immediately
        debugLog("[Anthropic] token from Keychain already expired, refreshing...")
        if let refreshed = try? await refreshAccessToken(refreshToken: creds.refreshToken) {
            debugLog("[Anthropic] refresh succeeded")
            return refreshed
        }

        // Refresh failed — try expired token anyway
        debugLog("[Anthropic] refresh failed, trying expired token")
        return creds.accessToken
    }

    /// In-memory credential cache to avoid repeated Keychain access.
    private struct CachedCredentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double
    }

    // MARK: - Credentials

    private struct OAuthCredentials {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Double  // epoch milliseconds
    }

    /// Loads full OAuth credentials from Keychain or credentials file.
    private static func loadCredentials() -> OAuthCredentials? {
        // Try Keychain first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data,
           let jsonStr = String(data: data, encoding: .utf8) {
            if let creds = parseOAuthCredentials(jsonStr) {
                return creds
            }
        }

        // Try credentials file
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
        if let claudeOAuth = obj["claudeAiOauth"] as? [String: Any],
           let access = claudeOAuth["accessToken"] as? String ?? claudeOAuth["access_token"] as? String {
            let refresh = claudeOAuth["refreshToken"] as? String ?? claudeOAuth["refresh_token"] as? String ?? ""
            let expires = claudeOAuth["expiresAt"] as? Double ?? 0
            return OAuthCredentials(accessToken: access, refreshToken: refresh, expiresAt: expires)
        }

        // Try direct fields
        if let access = obj["accessToken"] as? String ?? obj["access_token"] as? String {
            let refresh = obj["refreshToken"] as? String ?? obj["refresh_token"] as? String ?? ""
            let expires = obj["expiresAt"] as? Double ?? 0
            return OAuthCredentials(accessToken: access, refreshToken: refresh, expiresAt: expires)
        }

        return nil
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

        // Update keychain with new tokens
        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let newExpiresAt = (Date().timeIntervalSince1970 + expiresIn) * 1000

        // Update in-memory cache first (no Keychain prompt)
        TokenCache.shared.set("anthropic", value: newAccessToken)
        TokenCache.shared.setObject("anthropic_creds", value: CachedCredentials(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresAt: newExpiresAt
        ))

        // Update keychain in background (may trigger prompt on first write only)
        Self.updateKeychainTokens(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresAt: newExpiresAt
        )

        return newAccessToken
    }

    /// Updates the Keychain entry with refreshed tokens.
    private static func updateKeychainTokens(accessToken: String, refreshToken: String, expiresAt: Double) {
        // Read existing keychain data, update the claudeAiOauth section
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
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

        // Update the claudeAiOauth section
        if var claudeOAuth = obj["claudeAiOauth"] as? [String: Any] {
            claudeOAuth["accessToken"] = accessToken
            claudeOAuth["refreshToken"] = refreshToken
            claudeOAuth["expiresAt"] = expiresAt
            obj["claudeAiOauth"] = claudeOAuth
        }

        // Write back to keychain
        guard let updatedData = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: updatedData
        ]
        SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        debugLog("[Anthropic] updated keychain with new tokens")
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        // Parse five_hour window
        if let fiveHour = json["five_hour"] as? [String: Any] {
            let limits = parseWindow(fiveHour, name: "5-Hour Session", windowType: .fiveHour)
            if !limits.isEmpty {
                groups.append(UsageGroup(name: "5-Hour Session", limits: limits))
            }
        }

        // Parse seven_day (overall weekly)
        if let sevenDay = json["seven_day"] as? [String: Any] {
            let limits = parseWindow(sevenDay, name: "Weekly Overall", windowType: .weekly)
            if !limits.isEmpty {
                groups.append(UsageGroup(name: "Weekly Overall", limits: limits))
            }
        }

        // Parse seven_day_opus (Opus-specific weekly)
        if let opus = json["seven_day_opus"] as? [String: Any] {
            let limits = parseWindow(opus, name: "Weekly Opus", windowType: .weekly)
            if !limits.isEmpty {
                groups.append(UsageGroup(name: "Weekly — Opus", limits: limits))
            }
        }

        // Parse seven_day_sonnet
        if let sonnet = json["seven_day_sonnet"] as? [String: Any] {
            let limits = parseWindow(sonnet, name: "Weekly Sonnet", windowType: .weekly)
            if !limits.isEmpty {
                groups.append(UsageGroup(name: "Weekly — Sonnet", limits: limits))
            }
        }

        // Parse extra_usage (spend) — API returns values in cents
        if let extra = json["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            let spentCents = extra["used_credits"] as? Double ?? extra["spend"] as? Double ?? 0
            let limitCents = extra["monthly_limit"] as? Double ?? extra["limit"] as? Double ?? 0
            let spent = spentCents / 100.0
            let limit = limitCents / 100.0
            if limit > 0 {
                let util = extra["utilization"] as? Double
                let pct: Double
                if let u = util {
                    pct = min((u > 1.0 ? u / 100.0 : u), 1.0)
                } else {
                    pct = min(spent / limit, 1.0)
                }
                groups.append(UsageGroup(name: "Extra Usage", limits: [
                    UsageLimit(
                        name: "Monthly Spend",
                        percentUsed: pct,
                        detail: String(format: "$%.2f / $%.2f", spent, limit),
                        windowType: .monthly
                    )
                ]))
            }
        }

        if groups.isEmpty {
            // Return a placeholder if we got data but couldn't parse windows
            groups.append(UsageGroup(name: "Claude Usage", limits: [
                UsageLimit(name: "Connected", percentUsed: 0, detail: "No usage data available", windowType: .unknown)
            ]))
        }

        return groups
    }

    private func parseWindow(_ window: [String: Any], name: String, windowType: UsageLimit.WindowType) -> [UsageLimit] {
        let resetStr = (window["resets_at"] ?? window["reset_at"] ?? window["resetAt"]) as? String
        debugLog("[Anthropic] parseWindow '\(name)': \(window)")

        // Parse the reset date
        var resetDate: Date? = nil
        if let rs = resetStr {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetDate = f1.date(from: rs) ?? ISO8601DateFormatter().date(from: rs)
        }

        // Determine the window length in seconds
        let windowSeconds: Double
        switch windowType {
        case .fiveHour: windowSeconds = 5 * 3600
        case .weekly: windowSeconds = 7 * 24 * 3600
        default: windowSeconds = 5 * 3600
        }

        // Try "utilization" field — API may return 0-1 (fraction) or 0-100 (percent)
        if let utilization = window["utilization"] as? Double {
            var normalized = utilization > 1.0 ? utilization / 100.0 : utilization
            var clamped = min(max(normalized, 0.0), 1.0)

            // Detect stale data: reset time is in the past → window already reset
            if let rd = resetDate, rd.timeIntervalSinceNow <= 0 {
                debugLog("[Anthropic] '\(name)' reset time is in the past, treating as fresh")
                clamped = 0
            }
            // Detect fresh window: shows 100% used but reset time is almost full window away
            // (>80% of window remaining means the window just started)
            else if clamped >= 1.0, let rd = resetDate, rd.timeIntervalSinceNow > windowSeconds * 0.8 {
                debugLog("[Anthropic] '\(name)' looks like a fresh window (resets in \(rd.timeIntervalSinceNow)s, window=\(windowSeconds)s), treating as fresh")
                clamped = 0
            }

            let resetText: String?
            if clamped > 0, let rd = resetDate, rd.timeIntervalSinceNow > 0 {
                resetText = TimeFormatter.formatRemaining(rd.timeIntervalSinceNow)
            } else {
                resetText = nil
            }

            return [UsageLimit(
                name: name,
                percentUsed: clamped,
                detail: resetText,
                windowType: windowType
            )]
        }

        // Try "percent_used" or "percentUsed"
        if let pctUsed = window["percent_used"] as? Double ?? window["percentUsed"] as? Double {
            var normalized = pctUsed / 100.0

            // Same stale/fresh detection
            if let rd = resetDate, rd.timeIntervalSinceNow <= 0 {
                normalized = 0
            } else if normalized >= 1.0, let rd = resetDate, rd.timeIntervalSinceNow > windowSeconds * 0.8 {
                normalized = 0
            }

            let resetText: String?
            if normalized > 0, let rd = resetDate, rd.timeIntervalSinceNow > 0 {
                resetText = TimeFormatter.formatRemaining(rd.timeIntervalSinceNow)
            } else {
                resetText = nil
            }

            return [UsageLimit(
                name: name,
                percentUsed: normalized,
                detail: resetText,
                windowType: windowType
            )]
        }

        return []
    }

    private func parseResetTime(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        return TimeFormatter.formatResetTime(isoString: str)
    }
}
