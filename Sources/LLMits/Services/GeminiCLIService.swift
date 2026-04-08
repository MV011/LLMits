import Foundation

/// Fetches Gemini CLI usage from Google's Code Assist API.
///
/// Flow:
///   1. Read OAuth access token from ~/.gemini/oauth_creds.json
///   2. Call loadCodeAssist to discover the user's project ID and tier
///   3. Call retrieveUserQuota to get per-model remaining fractions and reset times
///   4. Group the 6-7 models into 3 buckets (Pro, Flash, Flash Lite)
///   5. Calculate used percentage and reset time for each bucket
struct GeminiCLIService: UsageService {
    private static let providerKey = "geminiCLI"
    private static let codeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal"
    private static let geminiCLIClientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"

    /// Known daily request limits per tier
    /// Source: https://geminicli.com/docs
    private static let tierLimits: [String: Int] = [
        "g1-ultra-tier": 2000,
        "enterprise-tier": 2000,
        "workspace-ai-ultra-tier": 2000,
        "g1-pro-tier": 1500,
        "standard-tier": 1500,
        "free-tier": 1000,
    ]

    func fetchUsage(token: String) async throws -> [UsageGroup] {
        if RateLimiter.shared.isLimited(Self.providerKey) {
            throw ServiceError.httpError(429)
        }

        // 1. Read OAuth creds
        let creds = try readOAuthCreds()
        let accessToken = try await resolveAccessToken(creds)

        // 2. Get project ID and tier via loadCodeAssist
        let projectInfo = try await loadCodeAssist(accessToken: accessToken)

        // 3. Fetch live quota from the API
        let quotaResponse = try await retrieveUserQuota(accessToken: accessToken, projectId: projectInfo.projectId)

        // 4. Build usage groups from the response
        let groups = buildUsageGroups(
            buckets: quotaResponse.buckets,
            tier: projectInfo.tier,
            tierName: projectInfo.tierName,
            email: readAccountEmail()
        )

        RateLimiter.shared.clear(Self.providerKey)
        return groups
    }

    // MARK: - OAuth

    private struct OAuthCreds {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Double?
    }

    private func readOAuthCreds() throws -> OAuthCreds {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credsPath = home.appendingPathComponent(".gemini/oauth_creds.json").path

        guard FileManager.default.fileExists(atPath: credsPath) else {
            throw ServiceError.noCredentials(
                "Gemini CLI not found. Install it and sign in with: gemini auth login"
            )
        }

        guard let data = FileManager.default.contents(atPath: credsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Could not parse ~/.gemini/oauth_creds.json")
        }

        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw ServiceError.noCredentials("No access token in ~/.gemini/oauth_creds.json")
        }

        return OAuthCreds(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiryDate: json["expiry_date"] as? Double
        )
    }

    private func resolveAccessToken(_ creds: OAuthCreds) async throws -> String {
        if let expiry = creds.expiryDate {
            let expiryDate = Date(timeIntervalSince1970: expiry / 1000)
            if expiryDate > Date().addingTimeInterval(60) {
                return creds.accessToken
            }
        }

        if let refreshToken = creds.refreshToken {
            do {
                return try await refreshAccessToken(refreshToken: refreshToken)
            } catch {
                debugLog("[GeminiCLI] Token refresh failed: \(error), using existing token")
            }
        }

        return creds.accessToken
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)",
            "client_id=\(Self.geminiCLIClientID)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ServiceError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw ServiceError.parseError("Failed to parse refresh token response")
        }

        return newToken
    }

    // MARK: - Code Assist API

    private struct ProjectInfo {
        let projectId: String
        let tier: String      // e.g. "g1-ultra-tier"
        let tierName: String  // e.g. "Gemini Code Assist in Google One AI Ultra"
    }

    private func loadCodeAssist(accessToken: String) async throws -> ProjectInfo {
        let url = URL(string: "\(Self.codeAssistEndpoint):loadCodeAssist")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = "{}".data(using: .utf8)

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
            throw ServiceError.parseError("Invalid JSON from loadCodeAssist")
        }

        guard let projectId = json["cloudaicompanionProject"] as? String else {
            throw ServiceError.parseError("No project ID in loadCodeAssist response")
        }

        // Prefer paidTier (subscription) over currentTier (base)
        let paidTier = json["paidTier"] as? [String: Any]
        let currentTier = json["currentTier"] as? [String: Any]
        let tier = (paidTier?["id"] as? String) ?? (currentTier?["id"] as? String) ?? "standard-tier"
        let tierName = (paidTier?["name"] as? String) ?? (currentTier?["name"] as? String) ?? "Gemini Code Assist"

        return ProjectInfo(projectId: projectId, tier: tier, tierName: tierName)
    }

    // MARK: - Quota API

    private struct QuotaBucket {
        let modelId: String
        let remainingFraction: Double
        let resetTime: String?
    }

    private struct QuotaResponse {
        let buckets: [QuotaBucket]
    }

    private func retrieveUserQuota(accessToken: String, projectId: String) async throws -> QuotaResponse {
        let url = URL(string: "\(Self.codeAssistEndpoint):retrieveUserQuota")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": projectId])

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

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBuckets = json["buckets"] as? [[String: Any]] else {
            throw ServiceError.parseError("Invalid JSON from retrieveUserQuota")
        }

        let buckets = rawBuckets.compactMap { bucket -> QuotaBucket? in
            guard let modelId = bucket["modelId"] as? String else { return nil }
            // Handle both Double (0.2) and Int (1) JSON values
            let remainingFraction: Double
            if let d = bucket["remainingFraction"] as? Double {
                remainingFraction = d
            } else if let i = bucket["remainingFraction"] as? Int {
                remainingFraction = Double(i)
            } else {
                return nil
            }
            return QuotaBucket(
                modelId: modelId,
                remainingFraction: remainingFraction,
                resetTime: bucket["resetTime"] as? String
            )
        }

        return QuotaResponse(buckets: buckets)
    }

    // MARK: - Build Usage Groups

    private enum ModelBucket: String, CaseIterable {
        case pro, flash, lite
        var displayName: String {
            switch self {
            case .pro: return "Pro"
            case .flash: return "Flash"
            case .lite: return "Flash Lite"
            }
        }
    }

    private func buildUsageGroups(
        buckets: [QuotaBucket],
        tier: String,
        tierName: String,
        email: String
    ) -> [UsageGroup] {
        // Determine daily limit from tier
        let dailyLimit = Self.tierLimits[tier] ?? 1000

        // Group API buckets by our three categories
        // Within each bucket, all models share the same remainingFraction
        var bucketData: [ModelBucket: (remainingFraction: Double, resetTime: Date?, models: [String])] = [:]

        for bucket in buckets {
            let category = classifyModel(bucket.modelId)
            let resetDate = parseISO8601(bucket.resetTime ?? "")

            if let existing = bucketData[category] {
                // All models in a bucket share the same fraction — use the first
                var models = existing.models
                models.append(bucket.modelId)
                bucketData[category] = (existing.remainingFraction, existing.resetTime ?? resetDate, models)
            } else {
                bucketData[category] = (bucket.remainingFraction, resetDate, [bucket.modelId])
            }
        }

        var limits: [UsageLimit] = []

        for category in [ModelBucket.pro, .flash, .lite] {
            let data = bucketData[category]
            let remainingFraction = data?.remainingFraction ?? 1.0
            let usedFraction = 1.0 - remainingFraction
            let usedRequests = Int(round(usedFraction * Double(dailyLimit)))
            let resetDate = data?.resetTime

            // Build detail string
            var parts: [String] = []
            parts.append("\(usedRequests) / \(dailyLimit) req")

            if let reset = resetDate, reset > Date() {
                let remaining = reset.timeIntervalSinceNow
                if let formatted = TimeFormatter.formatRemaining(remaining) {
                    parts.append("Resets in \(formatted)")
                }
            }

            limits.append(UsageLimit(
                name: category.displayName,
                percentUsed: usedFraction,
                detail: parts.joined(separator: " · "),
                windowType: .perDay
            ))
        }

        // Use tier name as the group header (e.g. "Google One AI Ultra")
        let shortTierName = tierName
            .replacingOccurrences(of: "Gemini Code Assist in ", with: "")
            .replacingOccurrences(of: "Gemini Code Assist", with: "Code Assist")

        return [UsageGroup(name: shortTierName, limits: limits)]
    }

    // MARK: - Helpers

    private func classifyModel(_ name: String) -> ModelBucket {
        let lower = name.lowercased()
        if lower.contains("flash-lite") || lower.contains("flash_lite") || lower.contains("lite") {
            return .lite
        }
        if lower.contains("pro") {
            return .pro
        }
        return .flash
    }

    private func readAccountEmail() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountsPath = home.appendingPathComponent(".gemini/google_accounts.json").path
        if let data = FileManager.default.contents(atPath: accountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String {
            return active
        }
        return "Gemini CLI"
    }

    private func parseISO8601(_ str: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = formatter.date(from: str) { return d }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: str)
    }
}
