import Foundation

/// Shared time formatting utility for reset countdowns and date parsing.
public enum TimeFormatter {

    // MARK: - ISO 8601 Parsing (cached formatters)

    /// Parses an ISO 8601 date string, trying fractional seconds first.
    public static func parseISO8601(_ string: String) -> Date? {
        _fractionalFormatter.date(from: string)
            ?? _standardFormatter.date(from: string)
            ?? _fractionalOffsetFormatter.date(from: string)
            ?? _offsetFormatter.date(from: string)
    }

    private static let _fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let _standardFormatter = ISO8601DateFormatter()

    /// `2026-08-14T10:54:53.882335+00:00` — some APIs emit numeric offsets
    /// with fractional seconds that the internet-datetime formatter rejects.
    private static let _fractionalOffsetFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withColonSeparatorInTimeZone]
        return f
    }()

    private static let _offsetFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        return f
    }()

    // MARK: - Window resolution

    /// Determines the effective usage for a window, correcting for stale API data.
    /// Returns the corrected `percentUsed` and the absolute `resetAt` (if known).
    ///
    /// Handles two stale-data cases:
    /// 1. Reset time is in the past → window already reset → 0% used.
    /// 2. Shows 100% used but less than 30 min elapsed in current window
    ///    → stale data from previous window → 0% used (countdown still shown).
    static func resolveWindow(
        percentUsed: Double,
        resetDateString: String?,
        windowSeconds: Double,
        now: Date = Date()
    ) -> (percentUsed: Double, resetAt: Date?) {
        resolveWindow(
            percentUsed: percentUsed,
            resetAt: resetDateString.flatMap(parseISO8601),
            windowSeconds: windowSeconds,
            now: now
        )
    }

    static func resolveWindow(
        percentUsed: Double,
        resetAt: Date?,
        windowSeconds: Double,
        now: Date = Date()
    ) -> (percentUsed: Double, resetAt: Date?) {
        let adjusted = min(max(percentUsed, 0), 1)

        guard let resetDate = resetAt else {
            return (adjusted, nil)
        }

        let remaining = resetDate.timeIntervalSince(now)

        if remaining <= 0 {
            return (0, nil)
        }

        let elapsed = windowSeconds - remaining
        if adjusted >= 1.0, elapsed < 1800 {
            debugLog("[TimeFormatter] stale-reset detected: elapsed=\(Int(elapsed))s < 1800s, zeroing out")
            return (0, resetDate)
        }

        return (adjusted, resetDate)
    }

    /// Legacy wrapper — prefer `resolveWindow`. Still used by a few call sites
    /// that only need the baked string during the transition.
    static func adjustForStaleReset(
        percentUsed: Double,
        resetDateString: String?,
        windowSeconds: Double
    ) -> (percentUsed: Double, resetDetail: String?) {
        let resolved = resolveWindow(
            percentUsed: percentUsed,
            resetDateString: resetDateString,
            windowSeconds: windowSeconds
        )
        return (resolved.percentUsed, resolved.resetAt.flatMap { formatRemaining($0.timeIntervalSinceNow) })
    }

    // MARK: - Reset date helpers

    static func parseResetDate(isoString: String?) -> Date? {
        guard let isoString, !isoString.isEmpty else { return nil }
        if let date = parseISO8601(isoString) { return date }
        if let epoch = Double(isoString) {
            return Date(timeIntervalSince1970: epoch)
        }
        return nil
    }

    static func parseResetDate(epochOrSeconds: Double?, isEpoch: Bool, now: Date = Date()) -> Date? {
        guard let val = epochOrSeconds else { return nil }
        return isEpoch ? Date(timeIntervalSince1970: val) : now.addingTimeInterval(val)
    }

    public static func windowType(fromPeriodType type: String?) -> UsageLimit.WindowType {
        guard let type else { return .unknown }
        let upper = type.uppercased()
        if upper.contains("WEEK") { return .weekly }
        if upper.contains("MONTH") { return .monthly }
        if upper.contains("DAY") && !upper.contains("FIVE") { return .daily }
        if upper.contains("HOUR") || upper.contains("SESSION") { return .fiveHour }
        return .unknown
    }

    // MARK: - Formatting

    /// Format seconds remaining as "Resets in Xd Yh Zm", "Resets in Yh Zm", "Resets in Zm", or "Resets in <1m".
    static func formatRemaining(_ seconds: TimeInterval) -> String? {
        guard seconds > 0 else { return nil }

        let totalSeconds = Int(seconds)
        let days = totalSeconds / 86400
        let hours = (totalSeconds % 86400) / 3600
        let minutes = (totalSeconds % 3600) / 60

        if days > 0 {
            return "Resets in \(days)d \(hours)h \(minutes)m"
        } else if hours > 0 {
            return "Resets in \(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "Resets in \(minutes)m"
        } else {
            return "Resets in <1m"
        }
    }

    /// Format from epoch timestamp or seconds-from-now.
    static func formatResetTime(epochOrSeconds: Double?, isEpoch: Bool) -> String? {
        guard let date = parseResetDate(epochOrSeconds: epochOrSeconds, isEpoch: isEpoch) else { return nil }
        return formatRemaining(date.timeIntervalSinceNow)
    }

    /// Format from an ISO 8601 timestamp string.
    static func formatResetTime(isoString: String) -> String? {
        guard let date = parseResetDate(isoString: isoString) else { return nil }
        return formatRemaining(date.timeIntervalSinceNow)
    }

    // MARK: - Window Duration Constants

    static let fiveHourSeconds: Double = 5 * 3600
    static let weeklySeconds: Double = 7 * 24 * 3600
}
