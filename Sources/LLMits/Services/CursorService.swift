import Foundation

/// Fetches Cursor usage from cursor.com APIs.
/// Authentication: reads JWT + user ID from Cursor's SQLite state.vscdb.
///
/// Primary endpoint: POST /api/dashboard/get-current-period-usage
/// Returns credit pool usage, billing cycle, and per-category percentages.
struct CursorService: UsageService {
    private static let providerKey = "cursor"

    // IMPORTANT: cursor.com without www — www.cursor.com returns 308 redirects
    private let usageURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    private let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        let cookie = try resolveCookie(manualToken: token)

        // Fetch usage data and stripe profile in parallel
        async let periodData = fetchPeriodUsage(cookie: cookie)
        async let stripeData = fetchStripe(cookie: cookie)

        let period = try await periodData
        let stripe = try? await stripeData

        RateLimiter.shared.clear(Self.providerKey)
        return parsePeriodUsage(period, stripe: stripe)
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

    // MARK: - Networking

    private func fetchPeriodUsage(cookie: String) async throws -> [String: Any] {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.httpBody = "{}".data(using: .utf8)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard/spending", forHTTPHeaderField: "Referer")
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
                guard let rHttp = rResponse as? HTTPURLResponse, rHttp.statusCode == 200 else {
                    throw ServiceError.httpError((rResponse as? HTTPURLResponse)?.statusCode ?? 0)
                }
                guard let json = try? JSONSerialization.jsonObject(with: rData) as? [String: Any] else {
                    throw ServiceError.parseError("Invalid JSON from Cursor (redirect)")
                }
                return json
            }
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

    private func parsePeriodUsage(_ period: [String: Any], stripe: [String: Any]?) -> [UsageGroup] {
        var limits: [UsageLimit] = []

        // Plan name from stripe
        let membershipType = stripe?["membershipType"] as? String ?? "ultra"
        let planName = formatPlanName(membershipType)
        let isOnBillableAuto = stripe?["isOnBillableAuto"] as? Bool ?? false

        // Billing cycle dates (timestamps in milliseconds)
        let cycleEndMs = (period["billingCycleEnd"] as? String).flatMap { Double($0) }
        var resetDetail: String? = nil
        if let endMs = cycleEndMs {
            let endDate = Date(timeIntervalSince1970: endMs / 1000)
            resetDetail = TimeFormatter.formatRemaining(endDate.timeIntervalSinceNow)
        }

        // Parse planUsage
        if let planUsage = period["planUsage"] as? [String: Any] {
            let totalSpend = planUsage["totalSpend"] as? Int ?? 0
            let limit = planUsage["limit"] as? Int ?? 0
            let remaining = planUsage["remaining"] as? Int ?? 0

            // These are credit-unit values (not cents) — display as percentage
            let autoPercent = planUsage["autoPercentUsed"] as? Double ?? 0
            let apiPercent = planUsage["apiPercentUsed"] as? Double ?? 0

            // --- Total usage bar ---
            if limit > 0 {
                let pct = min(Double(totalSpend) / Double(limit), 1.0)
                let spent = formatCredits(totalSpend)
                let cap = formatCredits(limit)
                var detail = "\(spent) / \(cap) credits used"
                if let rd = resetDetail { detail += " · \(rd)" }
                limits.append(UsageLimit(
                    name: "Total Usage",
                    percentUsed: pct,
                    detail: detail,
                    windowType: .monthly
                ))
            }

            // --- Auto mode usage ---
            if autoPercent > 0 {
                let autoMsg = period["autoModelSelectedDisplayMessage"] as? String
                var detail = autoMsg ?? String(format: "%.1f%% of included usage", autoPercent)
                if let rd = resetDetail, autoMsg == nil { detail += " · \(rd)" }
                limits.append(UsageLimit(
                    name: "Auto Mode",
                    percentUsed: min(autoPercent / 100.0, 1.0),
                    detail: detail,
                    windowType: .monthly
                ))
            }

            // --- API/Premium model usage ---
            if apiPercent > 0 {
                let apiMsg = period["namedModelSelectedDisplayMessage"] as? String
                var detail = apiMsg ?? String(format: "%.1f%% of included API usage", apiPercent)
                if let rd = resetDetail, apiMsg == nil { detail += " · \(rd)" }
                limits.append(UsageLimit(
                    name: "Premium Models",
                    percentUsed: min(apiPercent / 100.0, 1.0),
                    detail: detail,
                    windowType: .monthly
                ))
            }

            // --- Remaining credits ---
            if remaining > 0 && limit > 0 {
                let remPercent = Double(remaining) / Double(limit)
                limits.append(UsageLimit(
                    name: "Remaining",
                    percentUsed: 1.0 - remPercent,
                    detail: "\(formatCredits(remaining)) credits remaining",
                    windowType: .monthly
                ))
            }
        }

        // --- Spend limit ---
        if let spendLimit = period["spendLimitUsage"] as? [String: Any] {
            let individualLimit = spendLimit["individualLimit"] as? Int ?? 0
            let individualRemaining = spendLimit["individualRemaining"] as? Int ?? 0

            if individualLimit > 0 {
                let used = individualLimit - individualRemaining
                let pct = min(Double(used) / Double(individualLimit), 1.0)
                limits.append(UsageLimit(
                    name: "Spend Limit",
                    percentUsed: pct,
                    detail: "\(formatCredits(used)) / \(formatCredits(individualLimit)) spend cap",
                    windowType: .monthly
                ))
            }
        }

        // --- Overage billing ---
        if isOnBillableAuto {
            limits.append(UsageLimit(
                name: "Overage Billing",
                percentUsed: 0,
                detail: "Pay-as-you-go enabled",
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
        if lower.contains("ultra") { return "Cursor Ultra" }
        if lower.contains("pro_plus") || lower.contains("pro+") { return "Cursor Pro+" }
        if lower.contains("pro") { return "Cursor Pro" }
        if lower.contains("business") { return "Cursor Business" }
        if lower.contains("free") || lower.contains("hobby") { return "Cursor Free" }
        return type.isEmpty ? "Cursor" : "Cursor \(type.capitalized)"
    }

    /// Format credit units as readable strings
    /// Credit units appear to be in hundredths (e.g., 40000 = $400.00 or 400 credits)
    private func formatCredits(_ value: Int) -> String {
        let dollars = Double(value) / 100.0
        if dollars == Double(Int(dollars)) {
            return String(format: "$%.0f", dollars)
        }
        return String(format: "$%.2f", dollars)
    }
}
