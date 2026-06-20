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

        var accessToken = try await resolveAccessToken(manualToken: token)

        do {
            async let creditsTask = fetchBillingData(url: creditsURL, token: accessToken)
            async let plainTask = fetchBillingData(url: billingURL, token: accessToken)

            let (creditsData, plainData) = try await (creditsTask, plainTask)

            RateLimiter.shared.clear(Self.providerKey)
            return try parseBillingResponses(credits: creditsData, plain: plainData)
        } catch ServiceError.noCredentials {
            // Token might be stale (e.g. Grok CLI refreshed ~/.grok/auth.json while app was running) —
            // retry ONCE with a fresh read from the file (clear cache so resolve will reload).
            debugLog("[Grok] got auth error, retrying with fresh credentials from ~/.grok/auth.json")
            TokenCache.shared.remove(Self.providerKey)
            TokenCache.shared.removeObject(Self.providerKey + ".expiresAt")

            accessToken = try await resolveAccessToken(manualToken: token, forceFresh: true)

            async let creditsTask = fetchBillingData(url: creditsURL, token: accessToken)
            async let plainTask = fetchBillingData(url: billingURL, token: accessToken)

            let (creditsData, plainData) = try await (creditsTask, plainTask)

            RateLimiter.shared.clear(Self.providerKey)
            return try parseBillingResponses(credits: creditsData, plain: plainData)
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
            RateLimiter.shared.recordLimit(Self.providerKey)
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

        if let (token, expiresAt) = await loadFromGrokAuthJSONAsync() {
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

    private func loadFromGrokAuthJSON() -> (token: String, expiresAt: Date?)? {
        // sync version for any legacy calls
        loadFromGrokAuthJSONSync()
    }

    private func loadFromGrokAuthJSONAsync() async -> (token: String, expiresAt: Date?)? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: loadFromGrokAuthJSONSync())
            }
        }
    }

    private func loadFromGrokAuthJSONSync() -> (token: String, expiresAt: Date?)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = home.appendingPathComponent(".grok/auth.json")

        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // The file is a map of "issuer::client" -> { "key": "<JWT>", "refresh_token": ..., "expires_at": ... }
        for (_, value) in json {
            guard let entry = value as? [String: Any] else { continue }
            if let key = entry["key"] as? String, !key.isEmpty {
                let expiresAt: Date? = (entry["expires_at"] as? String).flatMap {
                    ISO8601DateFormatter().date(from: $0)
                }
                return (key, expiresAt)
            }
        }

        return nil
    }

    // MARK: - Response Parsing

    private func parseBillingResponses(credits: Data, plain: Data) throws -> [UsageGroup] {
        guard let creditsJson = try? JSONSerialization.jsonObject(with: credits) as? [String: Any],
              let plainJson = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response from Grok billing")
        }

        let creditsConfig = creditsJson["config"] as? [String: Any] ?? [:]
        let plainConfig = plainJson["config"] as? [String: Any] ?? [:]

        var limits: [UsageLimit] = []

        let resetDetail = Self.formatResetDetail(from: creditsConfig["currentPeriod"] as? [String: Any] ?? plainConfig["currentPeriod"] as? [String: Any])

        // Raw quota numbers (from plain billing) — these are the "counted number of credits"
        var rawUsed: Double?
        var rawLimit: Double?
        if let ml = plainConfig["monthlyLimit"] as? [String: Any],
           let u = plainConfig["used"] as? [String: Any] {
            rawLimit = (ml["val"] as? Double) ?? (ml["val"] as? Int).map(Double.init)
            rawUsed = (u["val"] as? Double) ?? (u["val"] as? Int).map(Double.init)
        }

        // Prefer calculating the bar % directly from the counted credits (raw used/limit).
        // This makes the visual bar, the "% used" text, and the numbers in parentheses consistent.
        // The creditUsagePercent field from the API often doesn't match the raw calculation
        // (off by ~100x in observations), so we treat the raw numbers as the source of truth
        // for "actual counted credits".
        if let limit = rawLimit, let used = rawUsed, limit > 0 {
            let pct = min(used / limit, 1.0)
            let usedPct = Int(round(pct * 100))
            var detail = "\(usedPct)% used"
            detail += String(format: " (%.0f / %.0f)", used, limit)
            if let r = resetDetail {
                detail += " · \(r)"
            }
            limits.append(UsageLimit(
                name: "Build Credits",
                percentUsed: pct,
                detail: detail,
                windowType: .monthly
            ))
        } else if let pct = creditsConfig["creditUsagePercent"] as? Double {
            // Fallback to API percent only if no raw numbers
            let normalized = pct > 1.0 ? pct / 100.0 : pct
            let usedPct = Int(round(normalized * 100))
            var detail = "\(usedPct)% used"
            if let r = resetDetail {
                detail += " · \(r)"
            }
            limits.append(UsageLimit(
                name: "Build Credits",
                percentUsed: min(normalized, 1.0),
                detail: detail,
                windowType: .monthly
            ))
        }

        // Secondary bar for On-Demand / Pay-as-you-go if the plan has it configured
        let onDemandCap = (creditsConfig["onDemandCap"] as? [String: Any] ?? plainConfig["onDemandCap"] as? [String: Any])?["val"]
        let onDemandUsed = (creditsConfig["onDemandUsed"] as? [String: Any] ?? plainConfig["onDemandUsed"] as? [String: Any])?["val"]
        if let cap = (onDemandCap as? Double) ?? (onDemandCap as? Int).map(Double.init), cap > 0,
           let used = (onDemandUsed as? Double) ?? (onDemandUsed as? Int).map(Double.init) {
            let pct = min(used / cap, 1.0)
            limits.append(UsageLimit(
                name: "On-Demand",
                percentUsed: pct,
                detail: String(format: "%.0f / %.0f", used, cap),
                windowType: .monthly
            ))
        }

        if limits.isEmpty {
            limits.append(UsageLimit(name: "Subscription", percentUsed: 0, detail: "Active", windowType: .monthly))
        }

        return [UsageGroup(name: "Grok Build", limits: limits)]
    }

    // MARK: - Helpers

    private static func formatResetDetail(from currentPeriod: [String: Any]?) -> String? {
        guard let cp = currentPeriod,
              let endStr = cp["end"] as? String ?? cp["billingPeriodEnd"] as? String else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: endStr) ?? ISO8601DateFormatter().date(from: endStr) else {
            // Fallback: try to pretty print the raw string like "2026-07-01"
            if let short = endStr.split(separator: "T").first {
                let parts = short.split(separator: "-")
                if parts.count == 3 {
                    let month = Int(parts[1]) ?? 0
                    let day = Int(parts[2]) ?? 0
                    let monthName = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][safe: month] ?? ""
                    if !monthName.isEmpty {
                        return "Resets \(monthName) \(day)"
                    }
                }
            }
            return nil
        }

        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return "Resets \(df.string(from: date))"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
