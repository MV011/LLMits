import Foundation

/// Shared time formatting utility for reset countdowns and date parsing.
enum TimeFormatter {

    // MARK: - ISO 8601 Parsing (cached formatters)

    /// Parses an ISO 8601 date string, trying fractional seconds first.
    static func parseISO8601(_ string: String) -> Date? {
        _fractionalFormatter.date(from: string)
            ?? _standardFormatter.date(from: string)
    }

    private static let _fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let _standardFormatter = ISO8601DateFormatter()

    // MARK: - Stale/Fresh Window Detection

    /// Determines the effective usage for a window, correcting for stale API data.
    /// Returns the corrected `percentUsed` and an optional reset detail string.
    ///
    /// Handles two stale-data cases:
    /// 1. Reset time is in the past → window already reset → 0% used.
    /// 2. Shows 100% used but less than 30 min elapsed in current window
    ///    → stale data from previous window → 0% used.
    static func adjustForStaleReset(
        percentUsed: Double,
        resetDateString: String?,
        windowSeconds: Double
    ) -> (percentUsed: Double, resetDetail: String?) {
        let adjusted = min(max(percentUsed, 0), 1)

        guard let rs = resetDateString, let resetDate = parseISO8601(rs) else {
            return (adjusted, nil)
        }

        let remaining = resetDate.timeIntervalSinceNow

        // Reset time in the past — window already reset
        if remaining <= 0 {
            return (0, nil)
        }

        // API reports exhausted but we're very early in the current window.
        // This means the window JUST reset and the API is showing stale data
        // from the previous window. 30 min covers the typical API staleness.
        let elapsed = windowSeconds - remaining
        if adjusted >= 1.0, elapsed < 1800 {
            debugLog("[TimeFormatter] stale-reset detected: elapsed=\(Int(elapsed))s < 1800s, zeroing out")
            return (0, nil)
        }

        let resetDetail = adjusted > 0 ? formatRemaining(remaining) : nil
        return (adjusted, resetDetail)
    }

    // MARK: - Formatting

    /// Format seconds remaining as "Resets in Xd Yh Zm", "Resets in Yh Zm", or "Resets in Zm".
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
        } else {
            return "Resets in \(minutes)m"
        }
    }

    /// Format from epoch timestamp or seconds-from-now.
    static func formatResetTime(epochOrSeconds: Double?, isEpoch: Bool) -> String? {
        guard let val = epochOrSeconds else { return nil }
        let remaining: TimeInterval = isEpoch
            ? Date(timeIntervalSince1970: val).timeIntervalSinceNow
            : val
        return formatRemaining(remaining)
    }

    /// Format from an ISO 8601 timestamp string.
    static func formatResetTime(isoString: String) -> String? {
        if let date = parseISO8601(isoString) {
            return formatRemaining(date.timeIntervalSinceNow)
        }
        // Try epoch seconds
        if let epoch = Double(isoString) {
            return formatRemaining(Date(timeIntervalSince1970: epoch).timeIntervalSinceNow)
        }
        return nil
    }

    // MARK: - Window Duration Constants

    static let fiveHourSeconds: Double = 5 * 3600
    static let weeklySeconds: Double = 7 * 24 * 3600
}
