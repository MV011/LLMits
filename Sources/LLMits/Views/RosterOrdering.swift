import Foundation

/// Pick usable accounts before blocked ones, then use the nearest weekly
/// deadline. A passed Codex deadline means ready since that date, not a new
/// recurring schedule. Model-specific limits do not block the whole account.
public enum RosterOrdering {
    public static func sorted(_ snapshots: [UsageSnapshot], at date: Date) -> [UsageSnapshot] {
        let ranked = snapshots.map { snapshot in
            let pills = RosterPills.pills(
                for: snapshot.provider, groups: snapshot.groups, at: date, fetchedAt: snapshot.fetchedAt
            ).filter { $0.label == "Wk" || $0.label == "5h" }
            let blocked = pills.filter { ($0.limit?.percentUsed(at: date) ?? 0) >= 1 }
            let rank = pills.isEmpty ? 2 : (blocked.isEmpty ? 0 : 1)
            let deadline: Date?
            if !blocked.isEmpty {
                // Both windows must be available. An exhausted window without
                // a reset time cannot be assumed to recover at a known date.
                deadline = blocked.allSatisfy { $0.limit?.resetAt != nil }
                    ? blocked.compactMap { $0.limit?.resetAt }.max() : nil
            } else {
                let window = pills.first { $0.label == "Wk" } ?? pills.first
                deadline = window?.nextReset(at: date) ?? window?.limit?.resetAt
            }
            return (snapshot: snapshot, rank: rank, deadline: deadline ?? .distantFuture)
        }
        return ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.deadline != b.deadline { return a.deadline < b.deadline }
            if a.snapshot.fetchedAt != b.snapshot.fetchedAt { return a.snapshot.fetchedAt > b.snapshot.fetchedAt }
            return a.snapshot.id < b.snapshot.id
        }.map(\.snapshot)
    }
}
