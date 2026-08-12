import Foundation

/// Fetches Grok Build / xAI usage via the Grok CLI credentials.
/// Auto-discovers from ~/.grok/auth.json (OIDC session token used by Grok Build).
///
/// Endpoint:
///   GET https://cli-chat-proxy.grok.com/v1/billing
struct GrokService: UsageService {
    private static let providerKey = "grok"
    private let creditsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        let accessToken = try await resolveAccessToken(manualToken: token)

        do {
            async let creditsTask = fetchBillingData(url: creditsURL, token: accessToken)
            async let plainTask = fetchBillingData(url: billingURL, token: accessToken)

            let (creditsData, plainData) = try await (creditsTask, plainTask)

            RateLimiter.shared.clear(Self.providerKey)
            return try GrokBillingParser.parse(credits: creditsData, plain: plainData)
        } catch ServiceError.noCredentials(let message) {
            // A pasted manual token can't be refreshed — retrying would just
            // re-send the identical token, guaranteed to fail.
            if token != "mock-token" && token != "mock" && !token.isEmpty {
                throw ServiceError.noCredentials(message)
            }

            // Token might be stale (e.g. Grok CLI refreshed ~/.grok/auth.json while app was running) —
            // retry ONCE with a fresh read from the file (clear cache so resolve will reload).
            debugLog("[Grok] got auth error, retrying with fresh credentials from ~/.grok/auth.json")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")

            let retryToken = try await resolveAccessToken(manualToken: token, forceFresh: true)

            async let creditsTask = fetchBillingData(url: creditsURL, token: retryToken)
            async let plainTask = fetchBillingData(url: billingURL, token: retryToken)

            let (creditsData, plainData) = try await (creditsTask, plainTask)

            RateLimiter.shared.clear(Self.providerKey)
            return try GrokBillingParser.parse(credits: creditsData, plain: plainData)
        }
    }

    private func fetchBillingData(url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return data
        case 401, 403:
            throw ServiceError.noCredentials("Grok credentials expired or invalid. Run `grok login` to re-authenticate.")
        case 429:
            let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
            RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
            throw ServiceError.httpError(429)
        default:
            throw ServiceError.httpError(httpResponse.statusCode)
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
                    let now = Date()
                    let buffer: TimeInterval = 5 * 60  // 5 minutes safety margin
                    if exp.timeIntervalSince(now) > buffer {
                        return cached
                    }
                    debugLog("[Grok] cached token expiring soon (at \(exp)), will re-read ~/.grok/auth.json")
                    // fall through to force fresh read from file
                } else {
                    // no expiry info cached (e.g. from env var or legacy), trust it
                    return cached
                }
            }
        }

        if let entry = await loadFromGrokAuthJSONAsync() {
            var token = entry.token
            var expiresAt = entry.expiresAt

            // The CLI only rotates the file while it's running — self-refresh
            // when the on-disk token is expired/expiring so tracking survives
            // without the user reopening grok. (Skipped automatically when a
            // live grok session or another refresher holds the lock.)
            if let exp = expiresAt, exp.timeIntervalSinceNow < 5 * 60,
               let refreshed = await GrokTokenRefresher.refreshIfSafe() {
                token = refreshed.token
                expiresAt = refreshed.expiresAt
            }

            TokenCache.shared.set(Self.providerKey, value: token)
            if let exp = expiresAt {
                TokenCache.shared.setObject(Self.providerKey + ".expiresAt", value: exp)
            } else {
                TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")
            }
            return token
        }

        // Fallback to XAI_API_KEY / GROK_CODE_XAI_API_KEY env for API-key users
        if let envKey = ProcessInfo.processInfo.environment["XAI_API_KEY"] ?? ProcessInfo.processInfo.environment["GROK_CODE_XAI_API_KEY"] {
            if !envKey.isEmpty {
                TokenCache.shared.set(Self.providerKey, value: envKey)
                // API keys from env typically don't have short expiry we track; no expiry object
                TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")
                return envKey
            }
        }

        throw ServiceError.noCredentials("Install Grok Build CLI and run `grok login`, or set XAI_API_KEY.")
    }

    func currentIdentity() async -> String? {
        await loadFromGrokAuthJSONAsync()?.email
    }

    private func loadFromGrokAuthJSONAsync() async -> (token: String, expiresAt: Date?, email: String?)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: loadFromGrokAuthJSONSync())
            }
        }
    }

    private func loadFromGrokAuthJSONSync() -> (token: String, expiresAt: Date?, email: String?)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".grok/auth.json")

        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The file is a map of "issuer::client" -> { "key": "<JWT>", "refresh_token": ..., "expires_at": ... }.
        // Stale entries survive `grok login`, so never take the first one dictionary
        // iteration happens to yield — pick the freshest credential instead.
        let now = Date()
        var best: (token: String, expiresAt: Date?, email: String?)?
        for (_, value) in json {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty else { continue }
            // NB: must parse fractional seconds — Grok writes "…T02:06:45.801970Z",
            // which a non-fractional ISO8601DateFormatter rejects (the old code's
            // bug: expiry always parsed nil, so proactive re-read never fired).
            let expiresAt = (entry["expires_at"] as? String).flatMap(TimeFormatter.parseISO8601)
            let email = entry["email"] as? String
            if let current = best {
                if Self.isEntryPreferred(expiresAt, over: current.expiresAt, now: now) {
                    best = (key, expiresAt, email)
                }
            } else {
                best = (key, expiresAt, email)
            }
        }
        return best
    }

    /// Ranking: any non-expired entry beats an expired one (no expiry counts as
    /// non-expired); within the same group a known, later expiry wins.
    /// Shared with GrokTokenRefresher so read and refresh pick the same entry.
    static func isEntryPreferred(_ candidate: Date?, over current: Date?, now: Date) -> Bool {
        let candidateValid = candidate.map { $0 > now } ?? true
        let currentValid = current.map { $0 > now } ?? true
        if candidateValid != currentValid { return candidateValid }
        switch (candidate, current) {
        case let (c?, k?): return c > k
        case (.some, nil): return true
        default: return false
        }
    }

}
