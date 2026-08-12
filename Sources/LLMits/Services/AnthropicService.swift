import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
/// Reads credentials from macOS Keychain (Claude Code CLI) or ~/.claude/.credentials.json.
///
/// Token strategy:
/// 1. Read Keychain/file ONCE per app lifecycle, cache in memory
/// 2. On 401, retry once with a fresh Keychain read
/// 3. On 429, use exponential backoff via RateLimiter
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

        let accessToken = try await TokenResolver.shared.resolve(manualToken: token)
        let (data, httpResponse) = try await makeRequest(accessToken: accessToken)

        switch httpResponse.statusCode {
        case 200:
            RateLimiter.shared.clear(Self.providerKey)
            return try parseUsageResponse(data)
        case 401, 403:
            // Token might be stale — retry ONCE with a fresh Keychain read
            debugLog("[Anthropic] got \(httpResponse.statusCode), retrying with fresh credentials")
            await TokenResolver.shared.invalidateCache()

            let freshToken = try await TokenResolver.shared.resolve(manualToken: token)
            let (retryData, retryResponse) = try await makeRequest(accessToken: freshToken)

            if retryResponse.statusCode == 200 {
                RateLimiter.shared.clear(Self.providerKey)
                return try parseUsageResponse(retryData)
            }

            // Still failing — clear everything and report
            debugLog("[Anthropic] retry also failed with \(retryResponse.statusCode)")
            await TokenResolver.shared.invalidateCache()
            throw ServiceError.noCredentials(
                "Claude credentials expired. Open Claude and run any command to refresh, then retry."
            )
        case 429:
            // Parse Retry-After header if present
            let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
            debugLog("[Anthropic] got 429, recording rate limit (Retry-After: \(retryAfterStr ?? "none"))")
            RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
            throw ServiceError.httpError(429)
        default:
            throw ServiceError.httpError(httpResponse.statusCode)
        }
    }

    /// The email of the account Claude Code is currently logged into,
    /// from ~/.claude.json → oauthAccount.emailAddress. Local read only.
    func currentIdentity() async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let path = home.appendingPathComponent(".claude.json")
                guard let data = try? Data(contentsOf: path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let account = json["oauthAccount"] as? [String: Any] else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: account["emailAddress"] as? String)
            }
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

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }

        var groups: [UsageGroup] = []

        // Preferred: the generic `limits` array. Each entry carries its own
        // kind/group/scope (including per-model weekly limits like Fable or
        // Opus via scope.model.display_name), so new models show up without
        // code changes — unlike the legacy fixed key list below.
        if let limitsArray = json["limits"] as? [[String: Any]] {
            groups += parseLimitsArray(limitsArray)
        }

        // Legacy fallback: fixed per-window keys (older API responses).
        if groups.isEmpty {
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

    /// Parses the modern `limits` array. Example entry:
    /// { "kind": "weekly_scoped", "group": "weekly", "percent": 5,
    ///   "resets_at": "…", "scope": { "model": { "display_name": "Fable" } } }
    private func parseLimitsArray(_ limits: [[String: Any]]) -> [UsageGroup] {
        var groups: [UsageGroup] = []

        for entry in limits {
            guard let kind = entry["kind"] as? String else { continue }
            let isWeekly = (entry["group"] as? String) == "weekly" || kind.hasPrefix("weekly")
            let windowType: UsageLimit.WindowType = isWeekly ? .weekly : .fiveHour

            let name: String
            switch kind {
            case "session":
                name = "5-Hour Session"
            case "weekly_all":
                name = "Weekly Overall"
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                name = (model ?? surface).map { "Weekly — \($0)" } ?? "Weekly — Scoped"
            default:
                name = kind.replacingOccurrences(of: "_", with: " ").capitalized
            }

            let percent = (entry["percent"] as? Double) ?? (entry["percent"] as? Int).map(Double.init) ?? 0
            let windowSeconds = isWeekly ? TimeFormatter.weeklySeconds : TimeFormatter.fiveHourSeconds
            let (adjusted, resetAt) = TimeFormatter.resolveWindow(
                percentUsed: percent / 100.0,
                resetDateString: entry["resets_at"] as? String,
                windowSeconds: windowSeconds
            )

            groups.append(UsageGroup(name: name, limits: [
                UsageLimit(name: name, percentUsed: adjusted, resetAt: resetAt, windowType: windowType)
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
            let (adjusted, resetAt) = TimeFormatter.resolveWindow(
                percentUsed: normalized, resetDateString: resetStr, windowSeconds: windowSeconds
            )
            debugLog("[Anthropic]   '\(name)' result: raw=\(normalized) adjusted=\(adjusted) resetAt=\(resetAt as Any)")
            return UsageLimit(name: name, percentUsed: adjusted, resetAt: resetAt, windowType: windowType)
        }

        // Try "percent_used" / "percentUsed"
        if let pctUsed = window["percent_used"] as? Double ?? window["percentUsed"] as? Double {
            let (adjusted, resetAt) = TimeFormatter.resolveWindow(
                percentUsed: pctUsed / 100.0, resetDateString: resetStr, windowSeconds: windowSeconds
            )
            return UsageLimit(name: name, percentUsed: adjusted, resetAt: resetAt, windowType: windowType)
        }

        return nil
    }
}

// MARK: - Token Resolution Actor

/// Serialized token resolver — ensures only ONE Keychain read happens at a time,
/// even when multiple tasks are fetching usage concurrently.
/// Caches credentials for the app's lifetime; only re-reads on explicit invalidation (e.g., after 401).
actor TokenResolver {
    static let shared = TokenResolver()

    private struct CachedCredentials {
        let accessToken: String
        let expiresAt: Double  // epoch milliseconds
        let readAt: Date       // when we cached this
    }

    private var cached: CachedCredentials?
    /// Single-flight guard: concurrent cold resolve() calls (e.g. two Claude
    /// accounts) share ONE interactive Keychain read instead of each
    /// triggering their own prompt. Actors are re-entrant, so the cache check
    /// alone can't serialize this.
    private var inFlight: Task<String, Error>?
    /// Minimum interval between Keychain reads (prevent hammering on repeated 401s)
    private let minReadInterval: TimeInterval = 5 // seconds
    private var lastReadTime: Date?

    /// After a failed/cancelled Keychain read, don't touch the Keychain again
    /// for this long — otherwise every timer tick re-triggers the interactive
    /// prompt. Cleared by invalidateCache() (e.g. credential-watcher events),
    /// so real logins are picked up immediately.
    private let failureCooldown: TimeInterval = 5 * 60
    private var lastFailure: Date?

    private init() {}

    /// Resolve the access token. Uses cache if valid, otherwise reads from Keychain/file.
    func resolve(manualToken: String) async throws -> String {
        // Manual token passthrough
        if manualToken != "mock-token" && manualToken != "mock" && !manualToken.isEmpty {
            return manualToken
        }

        // Check memory cache first — avoids Keychain prompts entirely
        if let c = cached {
            let nowMs = Date().timeIntervalSince1970 * 1000
            if c.expiresAt > nowMs + 60_000 {
                return c.accessToken
            }
            // Token expired in cache — but don't re-read if we just did
            debugLog("[TokenResolver] cached token expired, will re-read")
        }

        // Join an already-running read rather than starting a second one
        if let inFlight {
            return try await inFlight.value
        }

        let task = Task { try await self.readFreshCredentials() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// Clear the cache, forcing a fresh Keychain/file read on next resolve().
    /// Also clears the failure cooldown so credential-watcher events and 401
    /// retries always get a real read.
    func invalidateCache() {
        debugLog("[TokenResolver] cache invalidated")
        cached = nil
        lastFailure = nil
    }

    /// Read fresh credentials from Keychain (primary) or credentials files (fallback).
    /// Throttled to prevent hammering the Keychain on repeated failures.
    /// The actual Keychain SecItem access is offloaded to a GCD queue so we don't block
    /// Swift concurrency cooperative threads (or the main thread) while waiting for
    /// the user to approve the keychain permission dialog.
    private func readFreshCredentials() async throws -> String {
        // Throttle: don't re-read Keychain more than once per `minReadInterval`
        if let lastRead = lastReadTime,
           Date().timeIntervalSince(lastRead) < minReadInterval,
           let c = cached {
            debugLog("[TokenResolver] throttled, returning stale cached token")
            return c.accessToken
        }

        // Cooldown after a failed/cancelled read — without it, every timer tick
        // re-triggers the interactive Keychain prompt.
        if let failed = lastFailure,
           Date().timeIntervalSince(failed) < failureCooldown {
            debugLog("[TokenResolver] in failure cooldown, skipping Keychain read")
            throw ServiceError.noCredentials("Install Claude Code CLI and run 'claude' to login, or paste an OAuth token manually.")
        }

        debugLog("[TokenResolver] reading fresh credentials from Keychain/file")
        let loadResult = await Self.loadCredentialsAsync()
        guard let creds = loadResult.credentials else {
            lastFailure = Date()
            if loadResult.keychainStatus == errSecUserCanceled || loadResult.keychainStatus == errSecAuthFailed {
                // The user denied/cancelled the Keychain prompt — don't tell
                // them to install the CLI they already have.
                throw ServiceError.noCredentials("Keychain access to Claude credentials was denied — approve the prompt to continue.")
            }
            throw ServiceError.noCredentials("Install Claude Code CLI and run 'claude' to login, or paste an OAuth token manually.")
        }
        lastFailure = nil

        cached = CachedCredentials(
            accessToken: creds.accessToken,
            expiresAt: creds.expiresAt,
            readAt: Date()
        )
        lastReadTime = Date()

        let nowMs = Date().timeIntervalSince1970 * 1000
        if creds.expiresAt > nowMs + 60_000 {
            debugLog("[TokenResolver] fresh token valid, expires in \(Int((creds.expiresAt - nowMs) / 1000))s")
            return creds.accessToken
        }

        // Token already expired — use anyway (Claude CLI may not have refreshed yet)
        debugLog("[TokenResolver] fresh token already expired, using anyway")
        return creds.accessToken
    }

    // MARK: - Credentials Loading (static, no actor isolation needed)

    private struct FullCredentials {
        let accessToken: String
        let expiresAt: Double
    }

    /// Credentials plus the raw Keychain lookup status, so callers can
    /// distinguish "no credentials stored" from "user denied the prompt".
    private struct LoadResult {
        let credentials: FullCredentials?
        let keychainStatus: OSStatus
    }

    /// Performs the potentially interactive / blocking Keychain lookup off the Swift
    /// concurrency thread pool (and off the main thread) by dispatching to GCD.
    /// This prevents the app from appearing frozen while the user approves the
    /// Keychain permission dialog for "Claude Code-credentials".
    private static func loadCredentialsAsync() async -> LoadResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // === Original blocking Keychain + file fallback logic ===
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "Claude Code-credentials",
                    kSecReturnData as String: true,
                    kSecMatchLimit as String: kSecMatchLimitOne
                ]

                var result: AnyObject?
                let status = SecItemCopyMatching(query as CFDictionary, &result)

                if status == errSecSuccess, let data = result as? Data,
                   let jsonStr = String(data: data, encoding: .utf8),
                   let creds = parseCredentials(jsonStr) {
                    debugLog("[TokenResolver] loaded credentials from Keychain")
                    continuation.resume(returning: LoadResult(credentials: creds, keychainStatus: status))
                    return
                }

                if status != errSecSuccess && status != errSecItemNotFound {
                    debugLog("[TokenResolver] Keychain error: \(status)")
                }

                // Try credentials files as fallback
                let home = FileManager.default.homeDirectoryForCurrentUser
                for path in [
                    home.appendingPathComponent(".claude/.credentials.json"),
                    home.appendingPathComponent(".claude/credentials.json"),
                ] {
                    if let data = try? Data(contentsOf: path),
                       let jsonStr = String(data: data, encoding: .utf8),
                       let creds = parseCredentials(jsonStr) {
                        debugLog("[TokenResolver] loaded credentials from \(path.lastPathComponent)")
                        continuation.resume(returning: LoadResult(credentials: creds, keychainStatus: status))
                        return
                    }
                }

                continuation.resume(returning: LoadResult(credentials: nil, keychainStatus: status))
            }
        }
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
}
