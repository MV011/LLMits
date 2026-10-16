import Foundation

public struct RosterPill: Equatable {
    public var label: String
    public var kind: Kind
    public var limit: UsageLimit?

    public enum Kind: Equatable {
        case remainingPercent
        case fiveHourExhausted
        case resetPassed
    }

    public init(label: String, kind: Kind, limit: UsageLimit?) {
        self.label = label
        self.kind = kind
        self.limit = limit
    }

    public func resetDescription(at date: Date) -> String {
        guard let resetAt = limit?.resetAt else { return "reset time unavailable" }
        guard let remaining = TimeFormatter.formatCompactRemaining(resetAt.timeIntervalSince(date)) else {
            return "reset passed · refresh to update"
        }
        return "resets in \(remaining)"
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
            pills.append(pill(label: "Wk", limit: overall, at: date))
        }
        if let fable = limits.first(where: { $0.name.localizedCaseInsensitiveContains("Fable") }) {
            pills.append(pill(label: "Fable", limit: fable, at: date))
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

    private static func pill(label: String, limit: UsageLimit, at date: Date) -> RosterPill {
        let kind: RosterPill.Kind
        if let resetAt = limit.resetAt, resetAt <= date {
            kind = .resetPassed
        } else if limit.windowType == .fiveHour && limit.percentUsed >= 1 {
            kind = .fiveHourExhausted
        } else {
            kind = .remainingPercent
        }
        return RosterPill(label: label, kind: kind, limit: limit)
    }
}
