import Foundation

/// Shared Google OAuth helper for reading and refreshing tokens
/// from ~/.gemini/oauth_creds.json.
///
/// Used by AntigravityService (and formerly GeminiCLIService) to authenticate
/// against cloudcode-pa.googleapis.com APIs.
enum GoogleOAuthHelper {
    /// The OAuth2 client ID used by Gemini CLI / Antigravity CLI
    static let clientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"

    struct OAuthCreds {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Double?  // epoch milliseconds
    }

    // MARK: - Read Credentials

    /// Read OAuth credentials from ~/.gemini/oauth_creds.json.
    static func readOAuthCreds() throws -> OAuthCreds {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credsPath = home.appendingPathComponent(".gemini/oauth_creds.json").path

        guard FileManager.default.fileExists(atPath: credsPath) else {
            throw ServiceError.noCredentials(
                "Antigravity CLI not found. Install it and sign in with: agy"
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

    // MARK: - Resolve (with auto-refresh)

    /// Returns a valid access token, refreshing proactively if expired.
    /// Refreshed tokens are persisted back to ~/.gemini/oauth_creds.json so the
    /// CLI and subsequent requests reuse them instead of re-refreshing every call.
    static func resolveAccessToken(_ creds: OAuthCreds) async throws -> String {
        var knownExpired = false
        if let expiry = creds.expiryDate {
            let expiryDate = Date(timeIntervalSince1970: expiry / 1000)
            if expiryDate > Date().addingTimeInterval(60) {
                return creds.accessToken
            }
            knownExpired = true
        }

        if let refreshToken = creds.refreshToken {
            do {
                return try await refreshAndPersist(refreshToken: refreshToken)
            } catch where knownExpired {
                // The old token is guaranteed dead — surface the real cause
                // instead of deferring to a downstream 401.
                debugLog("[GoogleOAuth] Token refresh failed for expired token: \(error)")
                throw ServiceError.noCredentials(
                    "Google session expired and refresh failed. Re-authenticate with: agy"
                )
            } catch {
                // Expiry unknown — the existing token may still work, so fall through.
                debugLog("[GoogleOAuth] Token refresh failed: \(error), trying existing token")
            }
        }

        return creds.accessToken
    }

    // MARK: - Refresh

    /// Refresh the access token and write it back to ~/.gemini/oauth_creds.json
    /// so other tools (and future app launches) pick up the fresh token.
    static func refreshAndPersist(refreshToken: String) async throws -> String {
        let json = try await performTokenRefresh(refreshToken: refreshToken)
        guard let newToken = json["access_token"] as? String else {
            throw ServiceError.parseError("Failed to parse refresh token response")
        }

        // expires_in may arrive as Int or Double from Google's API
        let expiresIn: Double
        if let d = json["expires_in"] as? Double {
            expiresIn = d
        } else if let i = json["expires_in"] as? Int {
            expiresIn = Double(i)
        } else {
            expiresIn = 3600
        }
        let newExpiryMs = (Date().timeIntervalSince1970 + expiresIn) * 1000
        persistRefreshedToken(
            accessToken: newToken,
            expiryMs: newExpiryMs,
            refreshToken: json["refresh_token"] as? String
        )

        debugLog("[GoogleOAuth] token refreshed and persisted (expires in \(Int(expiresIn))s)")
        return newToken
    }

    /// Shared OAuth2 token refresh request. Returns the raw JSON response dict.
    static func performTokenRefresh(refreshToken: String) async throws -> [String: Any] {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)",
            "client_id=\(clientID)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            debugLog("[GoogleOAuth] OAuth refresh failed with HTTP \(code)")
            throw ServiceError.httpError(code)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Failed to parse refresh token response")
        }
        return json
    }

    // MARK: - Persistence

    /// Update ~/.gemini/oauth_creds.json with a new access token and expiry,
    /// preserving all other fields (refresh_token, scope, etc.). The file is
    /// re-read immediately before the atomic write so a refresh_token the CLI
    /// rotated in the meantime is preserved, not clobbered.
    static func persistRefreshedToken(accessToken: String, expiryMs: Double, refreshToken: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credsURL = home.appendingPathComponent(".gemini/oauth_creds.json")

        // Read existing file to preserve other fields
        guard let existingData = try? Data(contentsOf: credsURL),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            debugLog("[GoogleOAuth] could not read existing creds file for update")
            return
        }

        json["access_token"] = accessToken
        json["expiry_date"] = expiryMs
        if let refreshToken {
            json["refresh_token"] = refreshToken
        }

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            debugLog("[GoogleOAuth] could not serialize updated creds")
            return
        }

        // Retry once on transient failure before giving up.
        for attempt in 1...2 {
            do {
                try updatedData.write(to: credsURL, options: .atomic)
                // The atomic write recreates the file with default 0644 —
                // restore the CLI's 0600, this file holds a long-lived
                // Google refresh token.
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsURL.path)
                debugLog("[GoogleOAuth] persisted refreshed token to disk")
                return
            } catch {
                if attempt == 2 {
                    debugLog("[GoogleOAuth] failed to write refreshed token: \(error)")
                }
            }
        }
    }

    // MARK: - Account Email

    /// Read the active Google account email from ~/.gemini/google_accounts.json.
    static func readAccountEmail() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let accountsPath = home.appendingPathComponent(".gemini/google_accounts.json").path
        if let data = FileManager.default.contents(atPath: accountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let active = json["active"] as? String {
            return active
        }
        return "Antigravity"
    }
}
