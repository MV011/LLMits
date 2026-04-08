import Foundation

/// Fetches Cursor usage from cursor.com APIs.
/// Authentication: reads JWT + user ID from Cursor's SQLite state.vscdb.
///
/// Primary endpoints:
///   - GET /api/usage-summary — individual + team usage breakdown
///   - POST /api/dashboard/get-plan-info — plan name, price, included
///   - GET /api/auth/stripe — membership type fallback
struct CursorService: UsageService {
    private static let providerKey = "cursor"

    // IMPORTANT: cursor.com without www — www.cursor.com returns 308 redirects
    private let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private let planInfoURL = URL(string: "https://cursor.com/api/dashboard/get-plan-info")!
    private let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            let remaining = RateLimiter.shared.remainingSeconds(Self.providerKey)
            debugLog("[Cursor] rate limited for \(remaining)s more")
            throw ServiceError.httpError(429)
        }

        let cookie = try resolveCookie(manualToken: token)

        do {
            return try await fetchWithCookie(cookie)
        } catch ServiceError.httpError(let code) where code == 401 || code == 403 {
            // Session may have been refreshed by Cursor IDE — re-read the DB
            debugLog("[Cursor] got \(code), re-reading DB for fresh tokens")
            guard let freshCookie = Self.buildCookieFromDB() else {
                throw ServiceError.noCredentials(
                    "Cursor session expired. Open Cursor to refresh, then retry."
                )
            }
            // Only retry if we actually got a different cookie
            guard freshCookie != cookie else {
                throw ServiceError.noCredentials(
                    "Cursor session expired. Open Cursor to refresh, then retry."
                )
            }
            return try await fetchWithCookie(freshCookie)
        }
    }

    /// Core fetch logic — separated so we can retry with fresh credentials.
    private func fetchWithCookie(_ cookie: String) async throws -> [UsageGroup] {
        // Fetch all endpoints in parallel
        async let summaryData = fetchUsageSummary(cookie: cookie)
        async let planData = fetchPlanInfo(cookie: cookie)
        async let stripeData = fetchStripe(cookie: cookie)

        let summary = try await summaryData
        let planInfo = try? await planData
        let stripe = try? await stripeData

        RateLimiter.shared.clear(Self.providerKey)
        return parseUsageSummary(summary, planInfo: planInfo, stripe: stripe)
    }

    // MARK: - Cookie Resolution

    private func resolveCookie(manualToken: String) throws -> String {
        // Auto-discover from Cursor's SQLite state database
        if let cookie = Self.buildCookieFromDB() {
            return cookie
        }

        // Fallback: use manual token if provided
        if manualToken != "mock-token" && !manualToken.isEmpty {
            if manualToken.contains("WorkosCursorSessionToken") {
                return manualToken
            }
            return "WorkosCursorSessionToken=\(manualToken)"
        }

        throw ServiceError.noCredentials("Cursor is not logged in. Open Cursor and sign in, then retry.")
    }

    /// Reads tokens from Cursor's globalStorage/state.vscdb and builds
    /// the correct cookie format: workos_id=USER_ID; WorkosCursorSessionToken=USER_ID::JWT
    static func buildCookieFromDB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        // Use sqlite3 to read tokens
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, """
            SELECT key, value FROM ItemTable 
            WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken');
        """]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var accessToken: String?
        var refreshToken: String?

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0])
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "cursorAuth/accessToken":
                if value.hasPrefix("eyJ") { accessToken = value }
            case "cursorAuth/refreshToken":
                if value.hasPrefix("eyJ") { refreshToken = value }
            default: break
            }
        }

        // We need either access or refresh token — prefer refresh (longer-lived)
        let jwt = refreshToken ?? accessToken
        guard let jwt else { return nil }

        // Extract workos user ID from the JWT 'sub' field
        // sub format: "google-oauth2|user_01JFHV3WC4W87Q7CSWGSPGS3MP"
        let userId = extractUserIdFromJWT(jwt) ?? extractUserIdFromJWT(accessToken ?? "")
        guard let userId else { return nil }

        // Cookie format: workos_id=USER_ID; WorkosCursorSessionToken=USER_ID%3A%3AJWT
        return "workos_id=\(userId); WorkosCursorSessionToken=\(userId)%3A%3A\(jwt)"
    }

    /// Decodes a JWT and extracts the workos user ID from the `sub` claim
    private static func extractUserIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
        while base64.count % 4 != 0 { base64 += "=" }

        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = payload["sub"] as? String else {
            return nil
        }

        // sub is like "google-oauth2|user_01JFHV3WC4W87Q7CSWGSPGS3MP"
        if sub.contains("|") {
            return String(sub.split(separator: "|").last ?? "")
        }
        return sub
    }

    /// Legacy check used by auto-discovery — just verifies tokens exist
    static func readCursorJWT() -> String? {
        return buildCookieFromDB() != nil ? "found" : nil
    }

    private func fetchUsageSummary(cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: usageSummaryURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/usage", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10

        return try await performRequest(request, cookie: cookie)
    }

    private func fetchPlanInfo(cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: planInfoURL)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/usage", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 10

        return try await performRequest(request, cookie: cookie)
    }

    private func fetchStripe(cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: stripeURL)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        return try await performRequest(request, cookie: cookie)
    }

    private func performRequest(_ request: URLRequest, cookie: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.invalidResponse
        }

        // Handle redirects (www.cursor.com → cursor.com)
        if httpResponse.statusCode == 307 || httpResponse.statusCode == 308 {
            if let redirectURL = httpResponse.value(forHTTPHeaderField: "Location").flatMap({ URL(string: $0) }) {
                var redirectRequest = request
                redirectRequest.url = redirectURL
                let (rData, rResponse) = try await URLSession.shared.data(for: redirectRequest)
                guard let rHttp = rResponse as? HTTPURLResponse else {
                    throw ServiceError.invalidResponse
                }
                // Propagate auth errors from redirected request too
                guard rHttp.statusCode == 200 else {
                    throw ServiceError.httpError(rHttp.statusCode)
                }
                guard let json = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] else {
                    throw ServiceError.parseError("Invalid JSON from Cursor (redirect)")
                }
                return json
            }
        }

        if httpResponse.statusCode == 429 {
            let retryAfterStr = httpResponse.value(forHTTPHeaderField: "Retry-After")
            let retryAfter: TimeInterval? = retryAfterStr.flatMap { Double($0) }
            RateLimiter.shared.recordLimit(Self.providerKey, retryAfter: retryAfter)
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

    /// Parse the usage-summary response. Handles both individual and team plans.
    ///
    /// Team plan response has:
    ///   - limitType: "team"
    ///   - individualUsage.plan (included credits)
    ///   - individualUsage.onDemand (personal overage)
    ///   - teamUsage.onDemand (team total spend)
    ///
    /// Individual plan response has:
    ///   - limitType: "individual" or absent
    ///   - Same individualUsage structure but no teamUsage
    private func parseUsageSummary(
        _ summary: [String: Any],
        planInfo: [String: Any]?,
        stripe: [String: Any]?
    ) -> [UsageGroup] {
        var limits: [UsageLimit] = []

        // --- Determine plan name ---
        let planInfoObj = planInfo?["planInfo"] as? [String: Any]
        let planDisplayName = planInfoObj?["planName"] as? String
        let planPrice = planInfoObj?["price"] as? String
        let membershipType = summary["membershipType"] as? String ?? stripe?["membershipType"] as? String ?? ""
        let limitType = summary["limitType"] as? String ?? "individual"
        let isTeam = limitType == "team"

        let planName: String
        if let name = planDisplayName {
            planName = "Cursor \(name)"
        } else {
            planName = formatPlanName(membershipType)
        }

        // --- Billing cycle reset ---
        let cycleEnd = summary["billingCycleEnd"] as? String
        var resetDetail: String? = nil
        if let endStr = cycleEnd, let endDate = parseISO8601(endStr), endDate > Date() {
            resetDetail = TimeFormatter.formatRemaining(endDate.timeIntervalSinceNow)
        }
        // Fallback: try planInfo's billingCycleEnd (ms timestamp)
        if resetDetail == nil, let endMs = (planInfoObj?["billingCycleEnd"] as? String).flatMap({ Double($0) }) {
            let endDate = Date(timeIntervalSince1970: endMs / 1000)
            if endDate > Date() {
                resetDetail = TimeFormatter.formatRemaining(endDate.timeIntervalSinceNow)
            }
        }

        // --- Individual usage ---
        let individual = summary["individualUsage"] as? [String: Any]
        let planUsage = individual?["plan"] as? [String: Any]
        let onDemand = individual?["onDemand"] as? [String: Any]

        // Included plan usage
        if let planUsage {
            let used = planUsage["used"] as? Int ?? 0
            let limit = planUsage["limit"] as? Int ?? 0
            let apiPct = planUsage["apiPercentUsed"] as? Double ?? 0

            if limit > 0 {
                let pct = min(Double(used) / Double(limit), 1.0)
                var detail = "\(formatCents(used)) / \(formatCents(limit)) included"
                if let rd = resetDetail { detail += " · Resets in \(rd)" }
                limits.append(UsageLimit(
                    name: "Included Usage",
                    percentUsed: pct,
                    detail: detail,
                    windowType: .monthly
                ))
            }

            // Premium/API model bar — only if non-trivial and different from total
            if apiPct > 0 && abs(apiPct - (planUsage["totalPercentUsed"] as? Double ?? 0)) > 0.01 {
                let apiMsg = summary["namedModelSelectedDisplayMessage"] as? String
                let detail = apiMsg ?? String(format: "%.0f%% of included API usage", apiPct)
                limits.append(UsageLimit(
                    name: "Premium Models",
                    percentUsed: min(apiPct / 100.0, 1.0),
                    detail: detail,
                    windowType: .monthly
                ))
            }
        }

        // Individual on-demand (overage)
        if let onDemand, onDemand["enabled"] as? Bool == true {
            let usedCents = onDemand["used"] as? Int ?? 0
            if usedCents > 0 {
                // On-demand has no limit — show as spend bar
                limits.append(UsageLimit(
                    name: "Overage (You)",
                    percentUsed: 0, // no cap to measure against
                    detail: "\(formatCents(usedCents)) on-demand spend",
                    windowType: .monthly
                ))
            }
        }

        // --- Team usage (team plans only) ---
        if isTeam, let teamUsage = summary["teamUsage"] as? [String: Any] {
            let teamOnDemand = teamUsage["onDemand"] as? [String: Any]
            let teamUsedCents = teamOnDemand?["used"] as? Int ?? 0
            if teamUsedCents > 0 {
                limits.append(UsageLimit(
                    name: "Team Total",
                    percentUsed: 0, // no cap
                    detail: "\(formatCents(teamUsedCents)) total team spend",
                    windowType: .monthly
                ))
            }
        }

        // --- Plan info badge ---
        if let price = planPrice {
            let includedCents = planInfoObj?["includedAmountCents"] as? Int ?? 0
            var detail = price
            if includedCents > 0 {
                detail += " (\(formatCents(includedCents)) included)"
            }
            limits.append(UsageLimit(
                name: "Plan",
                percentUsed: 0,
                detail: detail,
                windowType: .monthly
            ))
        }

        if limits.isEmpty {
            limits.append(UsageLimit(
                name: planName,
                percentUsed: 0,
                detail: "No usage data available",
                windowType: .unknown
            ))
        }

        return [UsageGroup(name: planName, limits: limits)]
    }

    // MARK: - Helpers

    private func formatPlanName(_ type: String) -> String {
        let lower = type.lowercased()
        if lower.contains("enterprise") { return "Cursor Team" }
        if lower.contains("ultra") { return "Cursor Ultra" }
        if lower.contains("pro_plus") || lower.contains("pro+") { return "Cursor Pro+" }
        if lower.contains("pro") { return "Cursor Pro" }
        if lower.contains("business") { return "Cursor Business" }
        if lower.contains("free") || lower.contains("hobby") { return "Cursor Free" }
        return type.isEmpty ? "Cursor" : "Cursor \(type.capitalized)"
    }

    /// Shared currency formatter — avoids re-allocation on every call.
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    /// Format cent values as dollar strings.
    /// API values are in cents: 976970 → $9,769.70
    private func formatCents(_ cents: Int) -> String {
        let dollars = Double(cents) / 100.0
        let formatter = Self.currencyFormatter
        formatter.maximumFractionDigits = dollars == Double(Int(dollars)) ? 0 : 2
        return formatter.string(from: NSNumber(value: dollars)) ?? String(format: "$%.2f", dollars)
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
