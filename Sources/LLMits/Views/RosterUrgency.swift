import Foundation

enum RosterUrgency: Equatable {
    case none, ready, approaching, soon, urgent

    static func level(for snapshot: UsageSnapshot, at date: Date, isCurrent: Bool) -> Self {
        guard !isCurrent else { return .none }
        let pills = RosterPills.pills(for: snapshot.provider, groups: snapshot.groups,
                                     at: date, fetchedAt: snapshot.fetchedAt)
        let primary = pills.first { $0.label == "Wk" } ?? pills.first { $0.label == "5h" }
        guard let primary, primary.kind == .resetPassed else { return .none }
        guard !pills.contains(where: {
            ($0.label == "Wk" || $0.label == "5h") && ($0.limit?.percentUsed(at: date) ?? 0) >= 1
        }) else { return .none }
        // A passed session is not evidence that the weekly allowance is unused.
        // Codex has no fixed next cycle to project, so it stays simply ready.
        guard primary.repeatsWeekly, let next = primary.nextReset(at: date) else { return .ready }
        let hours = next.timeIntervalSince(date) / 3600
        if hours <= 6 { return .urgent }
        if hours <= 24 { return .soon }
        if hours <= 48 { return .approaching }
        return .ready
    }

    var accessibilityDescription: String {
        switch self {
        case .none: return ""
        case .ready: return "Estimated unused since reset"
        case .approaching: return "Estimated unused; weekly reset within two days"
        case .soon: return "Estimated unused; weekly reset within one day"
        case .urgent: return "Estimated unused; weekly reset within six hours"
        }
    }
}
