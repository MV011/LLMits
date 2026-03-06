import Foundation

/// Fetches Cursor usage from cursor.com/api/usage.
/// Authentication: reads JWT from Cursor's SQLite state.vscdb.
struct CursorService: UsageService {
    private let usageURL = URL(string: "https://www.cursor.com/api/usage")!
    private let stripeURL = URL(string: "https://www.cursor.com/api/auth/stripe")!
    private static let providerKey = "cursor"

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        let cookie = try resolveCookie(manualToken: token)

        // Fetch usage + stripe profile in parallel
        async let usageData = fetchJSON(url: usageURL, cookie: cookie)
        async let stripeData = fetchJSON(url: stripeURL, cookie: cookie)

        let usage = try await usageData
        let stripe = try? await stripeData

        RateLimiter.shared.clear(Self.providerKey)
        return parseUsage(usage, stripe: stripe)
    }

    // MARK: - Cookie Resolution

    private func resolveCookie(manualToken: String) throws -> String {
        // If user manually pasted a Cookie header or token
        if manualToken != "mock-token" && !manualToken.isEmpty {
            if manualToken.contains("=") {
                return manualToken
            }
            return "WorkosCursorSessionToken=\(manualToken)%3A%3A\(manualToken)"
        }

        // Auto-discover from Cursor's SQLite state database
        if let jwt = Self.readCursorJWT() {
            return "WorkosCursorSessionToken=\(jwt)%3A%3A\(jwt)"
        }

        throw ServiceError.noCredentials("Cursor is not logged in. Open Cursor and sign in, then retry.")
    }

    /// Reads the access token JWT from Cursor's globalStorage/state.vscdb.
    static func readCursorJWT() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        // Use Process+sqlite3 to avoid linking SQLite into the binary
        // IMPORTANT: read pipe BEFORE waitUntilExit to avoid pipe deadlock
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken';"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let jwt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jwt, !jwt.isEmpty, jwt.hasPrefix("eyJ") else { return nil }
        return jwt
    }

    // MARK: - Networking

    private func fetchJSON(url: URL, cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        if httpResponse.statusCode == 429 {
            RateLimiter.shared.recordLimit(Self.providerKey)
            throw ServiceError.httpError(429)
        }

        guard httpResponse.statusCode == 200 else {
            throw ServiceError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON from Cursor")
        }
        return json
    }

    // MARK: - Parsing

    private func parseUsage(_ usage: [String: Any], stripe: [String: Any]?) -> [UsageGroup] {
        var limits: [UsageLimit] = []

        // Parse gpt-4 usage (premium/fast requests)
        if let gpt4 = usage["gpt-4"] as? [String: Any] {
            let numRequests = gpt4["numRequests"] as? Int ?? gpt4["numRequestsTotal"] as? Int ?? 0
            let maxRequests = gpt4["maxRequestUsage"] as? Int

            if let max = maxRequests, max > 0 {
                let pct = min(Double(numRequests) / Double(max), 1.0)
                limits.append(UsageLimit(
                    name: "Premium Requests",
                    percentUsed: pct,
                    detail: "\(numRequests) / \(max) requests",
                    windowType: .monthly
                ))
            } else {
                // Unlimited (Pro plan) — show count only
                limits.append(UsageLimit(
                    name: "Premium Requests",
                    percentUsed: 0,
                    detail: "\(numRequests) requests used",
                    windowType: .monthly
                ))
            }

            // Extra/slow usage (tokens)
            let numTokens = gpt4["numTokens"] as? Int ?? 0
            let maxTokens = gpt4["maxTokenUsage"] as? Int
            if let max = maxTokens, max > 0 {
                let pct = min(Double(numTokens) / Double(max), 1.0)
                limits.append(UsageLimit(
                    name: "Extra Usage",
                    percentUsed: pct,
                    detail: "\(numTokens) / \(max) tokens",
                    windowType: .monthly
                ))
            } else if numTokens > 0 {
                limits.append(UsageLimit(
                    name: "Extra Usage",
                    percentUsed: 0,
                    detail: "\(numTokens) tokens",
                    windowType: .monthly
                ))
            }
        }

        // Billing period reset info
        var resetDetail: String? = nil
        if let startOfMonth = usage["startOfMonth"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let startDate = formatter.date(from: startOfMonth) {
                // Monthly billing — next reset is ~30 days from start
                let nextReset = Calendar.current.date(byAdding: .month, value: 1, to: startDate) ?? startDate
                resetDetail = TimeFormatter.formatRemaining(nextReset.timeIntervalSinceNow)
            }
        }

        // Add plan info from stripe
        let planName: String
        if let membershipType = stripe?["membershipType"] as? String {
            planName = membershipType.capitalized
        } else {
            planName = "Cursor"
        }

        // Apply reset detail to all limits
        if let reset = resetDetail {
            limits = limits.map { limit in
                UsageLimit(
                    name: limit.name,
                    percentUsed: limit.percentUsed,
                    detail: limit.detail.map { "\($0) · \(reset)" } ?? reset,
                    windowType: limit.windowType
                )
            }
        }

        if limits.isEmpty {
            limits.append(UsageLimit(
                name: planName,
                percentUsed: 0,
                detail: "No usage data",
                windowType: .unknown
            ))
        }

        return [UsageGroup(name: planName, limits: limits)]
    }
}
