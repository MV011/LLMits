import Foundation

/// Pure parser for `GET https://api.kimi.com/coding/v1/usages`.
///
/// Numeric fields arrive as JSON strings. Proto3-style responses omit
/// zero-valued fields (`used` disappears when the window is unused).
/// `resetTime` is an absolute ISO-8601 timestamp — store it as `resetAt`
/// so the UI can tick the countdown locally without another fetch.
public enum KimiUsageParser {

    public static func parse(_ data: Data) throws -> [UsageGroup] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError.parseError("Invalid JSON response")
        }
        return parse(json)
    }

    public static func parse(_ json: [String: Any]) -> [UsageGroup] {
        var groups: [UsageGroup] = []

        // Rolling rate-limit windows (currently a single 300-minute = 5h window).
        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                if let group = parseRateWindow(entry) {
                    groups.append(group)
                }
            }
        }

        // Weekly subscription quota
        if let usage = json["usage"] as? [String: Any],
           let group = parseWeeklyQuota(usage) {
            groups.append(group)
        }

        if groups.isEmpty {
            let level = ((json["user"] as? [String: Any])?["membership"] as? [String: Any])?["level"] as? String
            groups.append(UsageGroup(name: "Kimi Code", limits: [
                UsageLimit(
                    name: "Connected",
                    percentUsed: 0,
                    detail: level.map { membershipName($0) } ?? "No usage data",
                    windowType: .unknown
                )
            ]))
        }

        return groups
    }

    public static func parseRateWindow(_ entry: [String: Any]) -> UsageGroup? {
        guard let detail = entry["detail"] as? [String: Any],
              let limit = JSONNumber.double(from: detail["limit"]), limit > 0 else { return nil }

        let used = JSONNumber.double(from: detail["used"])
            ?? JSONNumber.double(from: detail["remaining"]).map { max(limit - $0, 0) }
            ?? 0

        let window = entry["window"] as? [String: Any]
        let windowSeconds = windowDurationSeconds(window)
        let isFiveHour = windowSeconds == nil || abs((windowSeconds ?? 18_000) - 18_000) < 60
        let windowType: UsageLimit.WindowType = isFiveHour ? .fiveHour : .unknown
        let name = isFiveHour ? "Kimi — 5h" : "Kimi — Rate Window"

        let (adjusted, resetAt) = TimeFormatter.resolveWindow(
            percentUsed: min(used / limit, 1.0),
            resetDateString: detail["resetTime"] as? String,
            windowSeconds: windowSeconds ?? TimeFormatter.fiveHourSeconds
        )

        return UsageGroup(name: name, limits: [
            UsageLimit(
                name: name,
                percentUsed: adjusted,
                detail: String(format: "%.0f / %.0f", used, limit),
                resetAt: resetAt,
                windowType: windowType
            )
        ])
    }

    static func parseWeeklyQuota(_ usage: [String: Any]) -> UsageGroup? {
        guard let limit = JSONNumber.double(from: usage["limit"]), limit > 0 else { return nil }

        let remaining = JSONNumber.double(from: usage["remaining"])
        let used = JSONNumber.double(from: usage["used"])
            ?? remaining.map { max(limit - $0, 0) }
            ?? 0
        let usedClamped = min(max(used, 0), limit)

        let (adjusted, resetAt) = TimeFormatter.resolveWindow(
            percentUsed: usedClamped / limit,
            resetDateString: usage["resetTime"] as? String,
            windowSeconds: TimeFormatter.weeklySeconds
        )

        return UsageGroup(name: "Kimi — Weekly", limits: [
            UsageLimit(
                name: "Kimi — Weekly",
                percentUsed: adjusted,
                detail: String(format: "%.0f / %.0f", usedClamped, limit),
                resetAt: resetAt,
                windowType: .weekly
            )
        ])
    }

    static func windowDurationSeconds(_ window: [String: Any]?) -> TimeInterval? {
        guard let window, let duration = JSONNumber.double(from: window["duration"]) else { return nil }
        switch window["timeUnit"] as? String {
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3600
        case "TIME_UNIT_DAY": return duration * 86_400
        case "TIME_UNIT_SECOND": return duration
        default: return nil
        }
    }

    /// "LEVEL_STANDARD" → "Standard"
    static func membershipName(_ level: String) -> String {
        level.replacingOccurrences(of: "LEVEL_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
