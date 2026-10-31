import Foundation
import Testing
@testable import LLMitsCore

struct RosterOrderingTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(_ name: String, provider: Provider = .anthropic,
                          weeklyReset: Date?, used: Double = 0.5,
                          sessionReset: Date? = nil, sessionUsed: Double = 0,
                          fetchedAt: Date? = nil) -> UsageSnapshot {
        let weeklyName = provider == .anthropic ? "Weekly Overall" : "Codex — Weekly"
        var groups = [UsageGroup(name: weeklyName, limits: [
            UsageLimit(name: weeklyName, percentUsed: used, resetAt: weeklyReset, windowType: .weekly)
        ])]
        if let sessionReset {
            let sessionName = provider == .anthropic ? "5-Hour Session" : "Codex — 5h"
            groups.append(UsageGroup(name: sessionName, limits: [
                UsageLimit(name: sessionName, percentUsed: sessionUsed, resetAt: sessionReset, windowType: .fiveHour)
            ]))
        }
        return UsageSnapshot(accountID: UUID(), provider: provider, fetchedAt: fetchedAt ?? now,
                             identity: name, groups: groups, error: nil)
    }

    private func order(_ snapshots: [UsageSnapshot], at date: Date? = nil) -> [String] {
        RosterOrdering.sorted(snapshots, at: date ?? now).compactMap(\.identity)
    }

    @Test func idleClaudeAccountsSortByNextWeeklyResetNotCacheAgeOrOriginalDate() {
        let soon = snapshot("soon", weeklyReset: now.addingTimeInterval(-20 * 86400),
                            used: 1, fetchedAt: now.addingTimeInterval(-30 * 86400))
        let later = snapshot("later", weeklyReset: now.addingTimeInterval(-24 * 86400), used: 1)
        let latest = snapshot("latest", weeklyReset: now.addingTimeInterval(-8 * 86400), used: 1)
        #expect(order([latest, later, soon]) == ["soon", "later", "latest"])
    }

    @Test func usableAccountsPrecedeExhaustedOnesAndKnownDeadlinesComeFirst() {
        let ready = snapshot("ready", weeklyReset: now.addingTimeInterval(5 * 86400))
        let blocked = snapshot("blocked", weeklyReset: now.addingTimeInterval(3600), used: 1)
        let unknown = snapshot("unknown", weeklyReset: nil)
        #expect(order([blocked, unknown, ready]) == ["ready", "unknown", "blocked"])
        #expect(order([unknown, ready]) == ["ready", "unknown"])
    }

    @Test func bothWindowsMustBeReadyAndBlockedAccountsSortByFullRecovery() {
        let sessionBlocked = snapshot("session", weeklyReset: now.addingTimeInterval(-86400), used: 1,
                                      sessionReset: now.addingTimeInterval(3600), sessionUsed: 1)
        let weeklyBlocked = snapshot("weekly", weeklyReset: now.addingTimeInterval(2 * 3600), used: 1,
                                     sessionReset: now.addingTimeInterval(60), sessionUsed: 1)
        let ready = snapshot("ready", weeklyReset: now.addingTimeInterval(6 * 86400))
        #expect(order([weeklyBlocked, sessionBlocked, ready]) == ["ready", "session", "weekly"])
        #expect(order([weeklyBlocked, sessionBlocked, ready], at: now.addingTimeInterval(3600)) ==
                ["ready", "session", "weekly"])
    }

    @Test func priorityUpdatesAsTheWeeklyBoundaryPasses() {
        let resetting = snapshot("resetting", weeklyReset: now.addingTimeInterval(60), used: 1)
        let usable = snapshot("usable", weeklyReset: now.addingTimeInterval(8 * 86400))
        #expect(order([resetting, usable]) == ["usable", "resetting"])
        #expect(order([resetting, usable], at: now.addingTimeInterval(60)) == ["resetting", "usable"])
    }

    @Test func codexReadyAccountsKeepOldestKnownResetFirst() {
        let older = snapshot("older", provider: .openai, weeklyReset: now.addingTimeInterval(-12 * 86400), used: 1)
        let newer = snapshot("newer", provider: .openai, weeklyReset: now.addingTimeInterval(-86400), used: 1)
        let future = snapshot("future", provider: .openai, weeklyReset: now.addingTimeInterval(86400))
        #expect(order([future, newer, older]) == ["older", "newer", "future"])
    }

    @Test func scopedModelExhaustionDoesNotBlockOtherModels() {
        var soon = snapshot("soon", weeklyReset: now.addingTimeInterval(3600))
        soon.groups.append(UsageGroup(name: "Weekly — Fable", limits: [
            UsageLimit(name: "Weekly — Fable", percentUsed: 1,
                       resetAt: now.addingTimeInterval(5 * 86400), windowType: .weekly)
        ]))
        let later = snapshot("later", weeklyReset: now.addingTimeInterval(86400))
        #expect(order([later, soon]) == ["soon", "later"])
    }

    @Test func unknownRecoveryAndEmptySnapshotsCannotOutrankKnownAvailability() {
        let ready = snapshot("ready", weeklyReset: now.addingTimeInterval(86400))
        let unknownRecovery = snapshot("unknown recovery", weeklyReset: nil, used: 1)
        let knownRecovery = snapshot("known recovery", weeklyReset: now.addingTimeInterval(3600), used: 1)
        var empty = ready
        empty.identity = "empty"
        empty.groups = []
        #expect(order([empty, unknownRecovery, ready, knownRecovery]) ==
                ["ready", "known recovery", "unknown recovery", "empty"])
    }

    @Test func tiedDatesHaveStableOrder() {
        let older = snapshot("older", weeklyReset: now.addingTimeInterval(86400), fetchedAt: now.addingTimeInterval(-60))
        let a = snapshot("a", weeklyReset: now.addingTimeInterval(86400))
        let b = snapshot("b", weeklyReset: now.addingTimeInterval(86400))
        #expect(order([b, older, a]) == ["a", "b", "older"])
    }
}
