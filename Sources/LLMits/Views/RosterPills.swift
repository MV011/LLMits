import Foundation

public struct RosterPill: Equatable {
    public var label: String
    public var kind: Kind
    public var limit: UsageLimit?

    public enum Kind: Equatable {
        case remainingPercent
        case resetCountdown
        case fiveHourExhausted
    }

    public init(label: String, kind: Kind, limit: UsageLimit?) {
        self.label = label
        self.kind = kind
        self.limit = limit
    }
}

public enum RosterPills {
    private static let longWindow: TimeInterval = 12 * 3600

    public static func pills(for provider: Provider, groups: [UsageGroup], at date: Date = Date()) -> [RosterPill] {
        switch provider {
        case .anthropic: return claude(groups: groups, at: date)
        case .openai: return codex(groups: groups, at: date)
        default: return []
        }
    }

    private static func claude(groups: [UsageGroup], at date: Date) -> [RosterPill] {
        let limits = groups.flatMap(\.limits)
        var pills: [RosterPill] = []

        if let overall = limits.first(where: { $0.name == "Weekly Overall" }) {
            pills.append(RosterPill(label: "Wk", kind: .remainingPercent, limit: overall))
        }
        if let fable = limits.first(where: { $0.name.localizedCaseInsensitiveContains("Fable") }) {
            pills.append(RosterPill(label: "Fable", kind: .remainingPercent, limit: fable))
        }
        if let fiveHour = limits.first(where: { $0.windowType == .fiveHour && $0.percentUsed(at: date) >= 1.0 }) {
            pills.append(RosterPill(label: "5h", kind: .fiveHourExhausted, limit: fiveHour))
        }
        return pills
    }

    private static func codex(groups: [UsageGroup], at date: Date) -> [RosterPill] {
        let mainLimits = groups
            .filter { $0.name.hasPrefix("Codex —") || $0.name.hasPrefix("Codex ") }
            .flatMap(\.limits)

        let weekly = mainLimits.first(where: { $0.windowType == .weekly })
            ?? mainLimits.first(where: { limit in
                guard let resetAt = limit.resetAt else { return false }
                return resetAt.timeIntervalSince(date) > longWindow
            })

        guard let weekly else { return [] }

        var pills = [RosterPill(label: "Wk", kind: .remainingPercent, limit: weekly)]
        if let resetAt = weekly.resetAt, resetAt > date {
            pills.append(RosterPill(label: "", kind: .resetCountdown, limit: weekly))
        }
        return pills
    }
}
