import Foundation

/// Shared per-provider rate limiter with exponential backoff.
/// Prevents repeated requests after receiving 429/rate-limit responses.
/// Consecutive 429s double the backoff: 30s → 60s → 120s → 240s (cap).
final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()

    private var backoffUntil: [String: Date] = [:]
    private var consecutiveHits: [String: Int] = [:]
    private let lock = NSLock()

    /// Base backoff in seconds (first 429 = 30s)
    private let baseBackoff: TimeInterval = 30
    /// Maximum backoff in seconds (cap at 4 min)
    private let maxBackoff: TimeInterval = 240

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

    /// Record a rate-limit hit with exponential backoff.
    /// Each consecutive 429 doubles the wait: 30s → 60s → 120s → 240s (cap).
    /// Pass `retryAfter` from the HTTP header to override the calculated backoff.
    func recordLimit(_ provider: String, retryAfter: TimeInterval? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let hits = (consecutiveHits[provider] ?? 0) + 1
        consecutiveHits[provider] = hits

        let backoff: TimeInterval
        if let retryAfter {
            backoff = retryAfter
        } else {
            // Exponential: base * 2^(hits-1), capped
            backoff = min(baseBackoff * pow(2.0, Double(hits - 1)), maxBackoff)
        }

        debugLog("[RateLimiter] \(provider): hit #\(hits), backing off \(Int(backoff))s")
        backoffUntil[provider] = Date().addingTimeInterval(backoff)
    }

    /// Clear backoff for a provider (e.g., after a successful request).
    func clear(_ provider: String) {
        lock.lock()
        defer { lock.unlock() }
        backoffUntil.removeValue(forKey: provider)
        consecutiveHits.removeValue(forKey: provider)
    }
}
