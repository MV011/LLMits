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

        let cookie = try await resolveCookie(manualToken: token)

        do {
            return try await fetchWithCookie(cookie)
        } catch ServiceError.httpError(let code) where code == 401 || code == 403 {
            // Session may have been refreshed by Cursor IDE — re-read the DB
            debugLog("[Cursor] got \(code), re-reading DB for fresh tokens")
            guard let freshCookie = await Self.buildCookieFromDBAsync() else {
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

    private func resolveCookie(manualToken: String) async throws -> String {
        // Auto-discover from Cursor's SQLite state database (offloaded to avoid blocking)
        if let cookie = await Self.buildCookieFromDBAsync() {
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

    /// Async version that offloads the blocking sqlite3 Process + wait to GCD.
    /// Prevents pinning Swift concurrency threads while spawning external processes.
    static func buildCookieFromDBAsync() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: buildCookieFromDBSync())
            }
        }
    }

    /// Synchronous implementation (used by the async wrapper and legacy discovery).
    private static func buildCookieFromDBSync() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dbPath = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path

        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        // Use sqlite3 to read tokens (via helper to centralize Process logic)
        guard let output = ProcessRunner.captureOutput(
            executable: "/usr/bin/sqlite3",
            arguments: [dbPath, """
                SELECT key, value FROM ItemTable 
                WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken');
            """]
        ) else { return nil }

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

    // Keep the old name as alias for discovery (which runs in detached task)
    static func buildCookieFromDB() -> String? {
        buildCookieFromDBSync()
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

    /// Parse the usage-summary response. Aligns individual Ultra/Pro plans with the
    /// Cursor web dashboard: Auto + Composer and API usage bars (percent-used, not dollar ratio).
    ///
    /// Team / enterprise fallbacks use `overall`, `pooled`, and on-demand spend when auto/api
    /// fields are absent.
    private func parseUsageSummary(
        _ summary: [String: Any],
        planInfo: [String: Any]?,
        stripe: [String: Any]?
    ) -> [UsageGroup] {
        let planInfoObj = planInfo?["planInfo"] as? [String: Any]
        let membershipType = summary["membershipType"] as? String ?? stripe?["membershipType"] as? String ?? ""
        let limitType = summary["limitType"] as? String ?? "individual"
        let isTeam = limitType == "team"

        let planName: String
        if let name = planInfoObj?["planName"] as? String {
            planName = name.lowercased().hasPrefix("cursor") ? name : "Cursor \(name)"
        } else {
            planName = formatPlanName(membershipType)
        }

        let resetSuffix = billingResetSuffix(summary: summary, planInfoObj: planInfoObj)
        let autoMessage = summary["autoModelSelectedDisplayMessage"] as? String
        let apiMessage = summary["namedModelSelectedDisplayMessage"] as? String

        var limits: [UsageLimit] = []
        let individual = summary["individualUsage"] as? [String: Any]
        let planUsage = individual?["plan"] as? [String: Any]

        if let planUsage {
            let autoPct = normPercent(planUsage["autoPercentUsed"])
            let apiPct = normPercent(planUsage["apiPercentUsed"])

            if let auto = autoPct {
                limits.append(UsageLimit(
                    name: "Auto + Composer",
                    percentUsed: auto / 100.0,
                    detail: composeDetail(message: autoMessage, resetSuffix: resetSuffix),
                    windowType: .monthly,
                    percentDisplay: .used
                ))
            }

            if let api = apiPct {
                limits.append(UsageLimit(
                    name: "API",
                    percentUsed: api / 100.0,
                    detail: composeDetail(message: apiMessage, resetSuffix: nil),
                    windowType: .monthly,
                    percentDisplay: .used
                ))
            }

            // Legacy / sparse plans without lane breakdown
            if limits.isEmpty {
                if let total = normPercent(planUsage["totalPercentUsed"]) {
                    limits.append(UsageLimit(
                        name: "Included",
                        percentUsed: total / 100.0,
                        detail: composeDetail(message: autoMessage, resetSuffix: resetSuffix),
                        windowType: .monthly,
                        percentDisplay: .used
                    ))
                } else {
                    let used = planUsage["used"] as? Int ?? 0
                    let limit = planUsage["limit"] as? Int ?? 0
                    if limit > 0 {
                        let pct = min(Double(used) / Double(limit), 1.0)
                        var detail = "\(formatCents(used)) / \(formatCents(limit)) included"
                        if let resetSuffix { detail += " · \(resetSuffix)" }
                        limits.append(UsageLimit(
                            name: "Included",
                            percentUsed: pct,
                            detail: detail,
                            windowType: .monthly
                        ))
                    }
                }
            }
        }

        // Enterprise / team member personal cap when plan block is missing or empty
        if limits.isEmpty, let overall = individual?["overall"] as? [String: Any] {
            appendCentsLimit(
                name: "Personal Cap",
                usage: overall,
                resetSuffix: resetSuffix,
                into: &limits
            )
        }

        // Shared team pool (assumption-based — not verified on this machine)
        if isTeam, let teamUsage = summary["teamUsage"] as? [String: Any],
           let pooled = teamUsage["pooled"] as? [String: Any] {
            appendCentsLimit(
                name: "Team Pool",
                usage: pooled,
                resetSuffix: resetSuffix,
                into: &limits
            )
        }

        // On-demand spend (only when non-zero)
        if let onDemand = individual?["onDemand"] as? [String: Any],
           onDemand["enabled"] as? Bool == true {
            let usedCents = onDemand["used"] as? Int ?? 0
            if usedCents > 0 {
                var detail = "\(formatCents(usedCents)) on-demand spend"
                if let limitCents = onDemand["limit"] as? Int, limitCents > 0 {
                    detail += " · \(formatCents(usedCents)) / \(formatCents(limitCents))"
                }
                limits.append(UsageLimit(
                    name: "On-Demand",
                    percentUsed: 0,
                    detail: detail,
                    windowType: .monthly
                ))
            }
        }

        if isTeam, let teamUsage = summary["teamUsage"] as? [String: Any],
           let teamOnDemand = teamUsage["onDemand"] as? [String: Any] {
            let teamUsed = teamOnDemand["used"] as? Int ?? 0
            if teamUsed > 0 {
                limits.append(UsageLimit(
                    name: "Team On-Demand",
                    percentUsed: 0,
                    detail: "\(formatCents(teamUsed)) team spend",
                    windowType: .monthly
                ))
            }
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

    private func normPercent(_ value: Any?) -> Double? {
        let raw: Double?
        if let d = value as? Double { raw = d }
        else if let i = value as? Int { raw = Double(i) }
        else { return nil }
        guard let v = raw else { return nil }
        if v < 0 { return 0 }
        if v > 100 { return 100 }
        return v
    }

    private func billingResetSuffix(summary: [String: Any], planInfoObj: [String: Any]?) -> String? {
        if let endStr = summary["billingCycleEnd"] as? String,
           let endDate = parseISO8601(endStr), endDate > Date(),
           let remaining = TimeFormatter.formatRemaining(endDate.timeIntervalSinceNow) {
            return remaining
        }
        if let endMs = (planInfoObj?["billingCycleEnd"] as? String).flatMap({ Double($0) }) {
            let endDate = Date(timeIntervalSince1970: endMs / 1000)
            if endDate > Date(), let remaining = TimeFormatter.formatRemaining(endDate.timeIntervalSinceNow) {
                return remaining
            }
        }
        return nil
    }

    private func composeDetail(message: String?, resetSuffix: String?) -> String? {
        var parts: [String] = []
        if let message, !message.isEmpty { parts.append(message) }
        if let resetSuffix, !resetSuffix.isEmpty { parts.append(resetSuffix) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func appendCentsLimit(
        name: String,
        usage: [String: Any],
        resetSuffix: String?,
        into limits: inout [UsageLimit]
    ) {
        let used = usage["used"] as? Int ?? 0
        let limit = usage["limit"] as? Int ?? 0
        guard limit > 0 else { return }
        let pct = min(Double(used) / Double(limit), 1.0)
        var detail = "\(formatCents(used)) / \(formatCents(limit))"
        if let resetSuffix { detail += " · \(resetSuffix)" }
        limits.append(UsageLimit(
            name: name,
            percentUsed: pct,
            detail: detail,
            windowType: .monthly
        ))
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
