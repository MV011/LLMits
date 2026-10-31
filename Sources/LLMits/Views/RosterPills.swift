import Foundation

public struct RosterPill: Equatable {
    public var label: String
    public var kind: Kind
    public var limit: UsageLimit?
    public var repeatsWeekly: Bool

    public enum Kind: Equatable {
        case remainingPercent
        case fiveHourExhausted
        case resetPassed
    }

    public init(label: String, kind: Kind, limit: UsageLimit?, repeatsWeekly: Bool = false) {
        self.label = label
        self.kind = kind
        self.limit = limit
        self.repeatsWeekly = repeatsWeekly
    }

    /// Only Claude's weekly windows have a fixed recurring schedule. Keep the
    /// provider's original timestamp intact; the next occurrence is an estimate.
    public func nextReset(at date: Date) -> Date? {
        guard let resetAt = limit?.resetAt else { return nil }
        if resetAt > date { return resetAt }
        guard repeatsWeekly else { return nil }
        let week: TimeInterval = 7 * 24 * 3600
        let cycles = floor(date.timeIntervalSince(resetAt) / week) + 1
        return resetAt.addingTimeInterval(cycles * week)
    }

    public func resetDescription(at date: Date) -> String {
        guard let resetAt = limit?.resetAt else { return "reset time unavailable" }
        if resetAt <= date {
            if let next = nextReset(at: date),
               let remaining = TimeFormatter.formatCompactRemaining(next.timeIntervalSince(date)) {
                return "ready · next reset in \(remaining) (est.)"
            }
            return "ready · refresh to confirm"
        }
        let remaining = TimeFormatter.formatCompactRemaining(resetAt.timeIntervalSince(date)) ?? "<1m"
        return "resets in \(remaining)"
    }

    public func resetDateDescription(at date: Date) -> String? {
        guard let resetAt = limit?.resetAt else { return nil }
        let displayDate = nextReset(at: date) ?? resetAt
        let prefix = resetAt > date ? "Reset" : (repeatsWeekly ? "Next" : "Ready since")
        let formatted = displayDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "\(prefix): \(formatted)"
    }

    public func resetHelp(at date: Date) -> String {
        guard let resetAt = limit?.resetAt else { return "No reset time in this snapshot" }
        let recorded = "Last recorded reset: \(resetAt.formatted(date: .complete, time: .shortened))."
        guard resetAt <= date else { return recorded }
        return recorded + " Remaining usage is estimated after this reset; refresh this account to confirm."
    }
}

public enum RosterPills {
    private static let longWindow: TimeInterval = 12 * 3600

    public static func pills(
        for provider: Provider,
        groups: [UsageGroup],
        at date: Date = Date(),
        fetchedAt: Date? = nil
    ) -> [RosterPill] {
        switch provider {
        case .anthropic: return claude(groups: groups, at: date)
        case .openai: return codex(groups: groups, at: date, fetchedAt: fetchedAt ?? date)
        default: return []
        }
    }

    private static func claude(groups: [UsageGroup], at date: Date) -> [RosterPill] {
        let limits = groups.flatMap(\.limits)
        var pills: [RosterPill] = []

        if let overall = limits.first(where: { $0.name == "Weekly Overall" }) {
            pills.append(pill(label: "Wk", limit: overall, at: date, repeatsWeekly: true))
        }
        if let fable = limits.first(where: { $0.name.localizedCaseInsensitiveContains("Fable") }) {
            pills.append(pill(label: "Fable", limit: fable, at: date, repeatsWeekly: fable.windowType == .weekly))
        }
        if let fiveHour = limits.first(where: { $0.windowType == .fiveHour }) {
            pills.append(pill(label: "5h", limit: fiveHour, at: date))
        }
        return pills
    }

    private static func codex(groups: [UsageGroup], at date: Date, fetchedAt: Date) -> [RosterPill] {
        let mainLimits = groups
            .filter { $0.name.hasPrefix("Codex —") || $0.name.hasPrefix("Codex ") }
            .flatMap(\.limits)

        let weekly = mainLimits.first(where: { $0.windowType == .weekly })
            ?? mainLimits.first(where: { limit in
                guard let resetAt = limit.resetAt else { return false }
                return resetAt.timeIntervalSince(fetchedAt) > longWindow
            })

        var pills: [RosterPill] = []
        if let weekly {
            pills.append(pill(label: "Wk", limit: weekly, at: date))
        }
        // Older snapshots may have labelled a weekly primary window as 5h.
        // The long-window fallback above must not also appear as a session.
        if let fiveHour = mainLimits.first(where: { $0.windowType == .fiveHour && $0 != weekly }) {
            pills.append(pill(label: "5h", limit: fiveHour, at: date))
        }
        return pills
    }

    private static func pill(label: String, limit: UsageLimit, at date: Date, repeatsWeekly: Bool = false) -> RosterPill {
        let kind: RosterPill.Kind
        if let resetAt = limit.resetAt, resetAt <= date {
            kind = .resetPassed
        } else if limit.windowType == .fiveHour && limit.percentUsed >= 1 {
            kind = .fiveHourExhausted
        } else {
            kind = .remainingPercent
        }
        return RosterPill(label: label, kind: kind, limit: limit, repeatsWeekly: repeatsWeekly)
    }
}
