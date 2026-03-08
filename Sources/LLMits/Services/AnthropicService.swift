import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
/// Reads credentials from macOS Keychain (Claude Code CLI) or ~/.claude/.credentials.json.
///
/// NOTE: We do NOT refresh OAuth tokens ourselves. Claude Code CLI manages
/// its own token lifecycle. We just re-read from Keychain when expired.
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

        let accessToken = try resolveAccessToken(manualToken: token)
        let (data, httpResponse) = try await makeRequest(accessToken: accessToken)

        switch httpResponse.statusCode {
        case 200:
            RateLimiter.shared.clear(Self.providerKey)
            return try parseUsageResponse(data)
        case 401:
            // Token expired — clear cache, Claude Code CLI will refresh it
            debugLog("[Anthropic] got 401, clearing cache (CLI will refresh token)")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.remove("\(Self.providerKey)_creds")
            throw ServiceError.httpError(401)
        case 429:
            debugLog("[Anthropic] got 429, backing off for 120s")
            RateLimiter.shared.recordLimit(Self.providerKey, backoffSeconds: 120)
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
        let expiresAt: Double  // epoch milliseconds
    }

    private func resolveAccessToken(manualToken: String) throws -> String {
        if manualToken != "mock-token" && !manualToken.isEmpty {
            return manualToken
        }

        // Check in-memory cache first (avoids Keychain prompts)
        if let cached: OAuthCredentials = TokenCache.shared.getObject("\(Self.providerKey)_creds") {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if cached.expiresAt > nowMs + 60_000 {
                return cached.accessToken
            }
            // Token expired — clear cache and re-read from Keychain
            // Claude Code CLI handles its own token refresh
            debugLog("[Anthropic] cached token expired, will re-read from Keychain")
            TokenCache.shared.remove("\(Self.providerKey)_creds")
            TokenCache.shared.remove(Self.providerKey)
        }

        // Read fresh credentials from Keychain/file
        guard let creds = Self.loadCredentials() else {
            throw ServiceError.noCredentials("Install Claude Code CLI and run 'claude' to login, or paste an OAuth token manually.")
        }

        // Cache in memory for subsequent calls
        TokenCache.shared.setObject("\(Self.providerKey)_creds", value: OAuthCredentials(
            accessToken: creds.accessToken,
            expiresAt: creds.expiresAt
        ))

        let nowMs = Date().timeIntervalSince1970 * 1000
        if creds.expiresAt > nowMs + 60_000 {
            TokenCache.shared.set(Self.providerKey, value: creds.accessToken)
            return creds.accessToken
        }

        // Token from Keychain is already expired — try it anyway
        // (Claude Code CLI may not have refreshed yet)
        debugLog("[Anthropic] token from Keychain already expired, using anyway")
        return creds.accessToken
    }

    // MARK: - Credentials Loading

    private struct FullCredentials {
        let accessToken: String
        let expiresAt: Double
    }

    private static func loadCredentials() -> FullCredentials? {
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
           let creds = parseCredentials(jsonStr) {
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
               let creds = parseCredentials(jsonStr) {
                return creds
            }
        }

        return nil
    }

    private static func parseCredentials(_ json: String) -> FullCredentials? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let source = (obj["claudeAiOauth"] as? [String: Any]) ?? obj

        guard let access = source["accessToken"] as? String ?? source["access_token"] as? String else {
            return nil
        }

        let expires = source["expiresAt"] as? Double ?? 0
        return FullCredentials(accessToken: access, expiresAt: expires)
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

        debugLog("[Anthropic] parseWindow '\(name)': utilization=\(window["utilization"] ?? "nil"), percent_used=\(window["percent_used"] ?? "nil"), resets_at=\(resetStr ?? "nil")")

        // Try "utilization" field
        if let utilization = window["utilization"] as? Double {
            let normalized = utilization > 1.0 ? utilization / 100.0 : utilization
            let (adjusted, detail) = TimeFormatter.adjustForStaleReset(
                percentUsed: normalized, resetDateString: resetStr, windowSeconds: windowSeconds
            )
            debugLog("[Anthropic]   '\(name)' result: raw=\(normalized) adjusted=\(adjusted) detail=\(detail ?? "nil")")
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
