import Foundation

/// Shared time formatting utility for reset countdowns.
enum TimeFormatter {
    /// Format seconds remaining as "Xd Yh Zm", "Yh Zm", or "Zm".
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
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f1.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString) {
            return formatRemaining(date.timeIntervalSinceNow)
        }
        // Try epoch seconds
        if let epoch = Double(isoString) {
            return formatRemaining(Date(timeIntervalSince1970: epoch).timeIntervalSinceNow)
        }
        return nil
    }
}
