import Foundation

protocol UsageService {
    func fetchUsage(token: String) async throws -> [UsageGroup]

    /// The identity (email or user id) the currently-used credential belongs to.
    /// Must be cheap and local-only (config file reads, JWT decodes) — never a
    /// network call. Returns nil when the identity can't be determined.
    ///
    /// This is what lets the UI stay honest when the user switches accounts in
    /// the underlying CLI: the fetched data always follows the live credential,
    /// so the displayed identity must too.
    func currentIdentity() async -> String?
}

extension UsageService {
    func currentIdentity() async -> String? { nil }
}
