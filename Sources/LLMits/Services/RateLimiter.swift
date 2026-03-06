import Foundation

/// Shared per-provider rate limiter with backoff.
/// Prevents repeated requests after receiving 429/rate-limit responses.
final class RateLimiter {
    static let shared = RateLimiter()

    private var backoffUntil: [String: Date] = [:]
    private let lock = NSLock()

    private init() {}

    /// Check if a provider is currently in a backoff period.
    func isLimited(_ provider: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let until = backoffUntil[provider] else { return false }
        if until.timeIntervalSinceNow > 0 {
            return true
        }
        backoffUntil.removeValue(forKey: provider)
        return false
    }

    /// Seconds remaining in the backoff period (0 if not limited).
    func remainingSeconds(_ provider: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let until = backoffUntil[provider] else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow))
    }

    /// Record a rate-limit hit for a provider.
    func recordLimit(_ provider: String, backoffSeconds: TimeInterval = 60) {
        lock.lock()
        defer { lock.unlock() }
        backoffUntil[provider] = Date().addingTimeInterval(backoffSeconds)
    }

    /// Clear backoff for a provider (e.g., after a successful request).
    func clear(_ provider: String) {
        lock.lock()
        defer { lock.unlock() }
        backoffUntil.removeValue(forKey: provider)
    }
}
