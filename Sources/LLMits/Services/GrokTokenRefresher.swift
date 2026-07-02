import Foundation

/// Self-refreshes the Grok CLI OAuth session using its refresh token, so usage
/// tracking keeps working after the ~6h access token expires even when the
/// Grok CLI isn't running to rotate it.
///
/// xAI rotates refresh tokens (single-use): every refresh invalidates the old
/// refresh token and returns a new one, so exactly one holder of the current
/// token can exist. The protocol below keeps that holder consistent between
/// this app and the CLI:
/// 1. Skip entirely while a live `grok` session is running — its in-memory
///    refresh token would be silently invalidated by our rotation, forcing the
///    user through interactive re-login.
/// 2. Take the CLI's own lock file (~/.grok/auth.json.lock, flock) around the
///    whole read → refresh → write sequence.
/// 3. Re-read auth.json under the lock and refresh only the token actually on
///    disk — refreshing a copy cached earlier could burn a token the CLI
///    already rotated.
/// 4. Persist key + refresh_token + expires_at atomically before releasing.
enum GrokTokenRefresher {
    /// Confirmed via https://auth.x.ai/.well-known/openid-configuration
    private static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!

    /// After a failed refresh, don't retry for a while — a dead refresh token
    /// must not turn the periodic refresh loop into token-endpoint spam.
    private static let failureCooldown: TimeInterval = 10 * 60
    private static let cooldownKey = "grok.refreshFailedAt"

    static func refreshIfSafe() async -> (token: String, expiresAt: Date?)? {
        if let failedAt: Date = TokenCache.shared.getObject(cooldownKey),
           Date().timeIntervalSince(failedAt) < failureCooldown {
            debugLog("[GrokRefresh] in failure cooldown, skipping")
            return nil
        }

        if await hasLiveCLISession() {
            debugLog("[GrokRefresh] live grok session detected, deferring to the CLI")
            return nil
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".grok/auth.json")
        let lockURL = home.appendingPathComponent(".grok/auth.json.lock")

        let lockFD = open(lockURL.path, O_WRONLY | O_CREAT, 0o600)
        guard lockFD >= 0 else { return nil }

        var locked = false
        for _ in 0..<8 {
            if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard locked else {
            close(lockFD)
            debugLog("[GrokRefresh] could not acquire auth.json.lock, skipping")
            return nil
        }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        // Re-read under the lock — never refresh a token read before we held it.
        guard let data = try? Data(contentsOf: authURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let (entryKey, entry) = bestEntry(in: json) else {
            return nil
        }

        // Someone (the CLI) may have refreshed while we waited for the lock.
        if let key = entry["key"] as? String, !key.isEmpty,
           let exp = (entry["expires_at"] as? String).flatMap(TimeFormatter.parseISO8601),
           exp.timeIntervalSinceNow > 5 * 60 {
            debugLog("[GrokRefresh] disk token already fresh, using it")
            return (key, exp)
        }

        guard let refreshToken = entry["refresh_token"] as? String, !refreshToken.isEmpty,
              let clientID = entry["oidc_client_id"] as? String, !clientID.isEmpty else {
            debugLog("[GrokRefresh] entry has no refresh_token/client_id")
            return nil
        }

        // The network call happens while holding the lock: rotation makes
        // read + refresh + write one atomic unit as far as the CLI is concerned.
        guard let refreshed = await performRefresh(refreshToken: refreshToken, clientID: clientID) else {
            TokenCache.shared.setObject(cooldownKey, value: Date())
            return nil
        }

        let expiresAt = Date().addingTimeInterval(refreshed.expiresIn ?? 3600)
        var updated = entry
        updated["key"] = refreshed.accessToken
        // Always persist the returned refresh token — the old one is dead now.
        if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
            updated["refresh_token"] = newRefresh
        }
        updated["expires_at"] = isoFormatter.string(from: expiresAt)
        json[entryKey] = updated

        if let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            do {
                try out.write(to: authURL, options: .atomic)
                debugLog("[GrokRefresh] token refreshed and persisted (expires in \(Int(refreshed.expiresIn ?? 3600))s)")
            } catch {
                // The rotated refresh token now exists only in memory; the CLI
                // will have to re-login interactively. Still return the fresh
                // access token — the old lineage is burned either way.
                debugLog("[GrokRefresh] WARNING: failed to persist rotated tokens: \(error)")
            }
        }

        TokenCache.shared.removeObject(cooldownKey)
        return (refreshed.accessToken, expiresAt)
    }

    // MARK: - Safety checks

    /// True when any grok CLI session listed in active_sessions.json is still
    /// alive. Stale entries linger in the file, so verify the PID.
    private static func hasLiveCLISession() async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let path = home.appendingPathComponent(".grok/active_sessions.json")
                guard let data = try? Data(contentsOf: path),
                      let sessions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    cont.resume(returning: false)
                    return
                }
                let alive = sessions.contains { session in
                    guard let pid = session["pid"] as? Int else { return false }
                    // kill(pid, 0) probes existence; EPERM still means alive.
                    return kill(pid_t(pid), 0) == 0 || errno == EPERM
                }
                cont.resume(returning: alive)
            }
        }
    }

    /// Same freshest-entry ranking GrokService uses for reads.
    private static func bestEntry(in json: [String: Any]) -> (key: String, entry: [String: Any])? {
        let now = Date()
        var best: (key: String, entry: [String: Any], expiresAt: Date?)?
        for (dictKey, value) in json {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            let expiresAt = (entry["expires_at"] as? String).flatMap(TimeFormatter.parseISO8601)
            if let current = best {
                if GrokService.isEntryPreferred(expiresAt, over: current.expiresAt, now: now) {
                    best = (dictKey, entry, expiresAt)
                }
            } else {
                best = (dictKey, entry, expiresAt)
            }
        }
        return best.map { ($0.key, $0.entry) }
    }

    // MARK: - Token endpoint

    private struct RefreshResponse {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
    }

    private static func performRefresh(refreshToken: String, clientID: String) async -> RefreshResponse? {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)",
            "client_id=\(clientID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clientID)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            debugLog("[GrokRefresh] token endpoint request failed")
            return nil
        }
        guard http.statusCode == 200 else {
            debugLog("[GrokRefresh] token endpoint returned \(http.statusCode)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else {
            debugLog("[GrokRefresh] could not parse token response")
            return nil
        }

        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init)
        return RefreshResponse(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: expiresIn
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
