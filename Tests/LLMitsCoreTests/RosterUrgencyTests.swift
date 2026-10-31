import Foundation
import Testing
@testable import LLMitsCore

struct RosterUrgencyTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func snapshot(provider: Provider = .anthropic, reset: Date?, used: Double = 1) -> UsageSnapshot {
        let name = provider == .anthropic ? "Weekly Overall" : "Codex — Weekly"
        return UsageSnapshot(accountID: UUID(), provider: provider, fetchedAt: now.addingTimeInterval(-8 * 86400),
                             identity: "cached-account", groups: [UsageGroup(name: name, limits: [
                                UsageLimit(name: name, percentUsed: used, resetAt: reset, windowType: .weekly)
                             ])], error: nil)
    }

    @Test func unusedWeeklyCycleGetsMoreUrgentAndClearsAtRollover() {
        let reset = now.addingTimeInterval(-3600)
        let account = snapshot(reset: reset)
        #expect(RosterUrgency.level(for: account, at: now, isCurrent: false) == .ready)
        #expect(RosterUrgency.level(for: account, at: reset.addingTimeInterval(5 * 86400), isCurrent: false) == .approaching)
        #expect(RosterUrgency.level(for: account, at: reset.addingTimeInterval(6 * 86400), isCurrent: false) == .soon)
        #expect(RosterUrgency.level(for: account, at: reset.addingTimeInterval(7 * 86400 - 6 * 3600), isCurrent: false) == .urgent)
        #expect(RosterUrgency.level(for: account, at: reset.addingTimeInterval(7 * 86400), isCurrent: false) == .ready)
    }

    @Test func currentOrNotYetResetAccountsAreNotMarkedUnused() {
        let expired = snapshot(reset: now.addingTimeInterval(-6.9 * 86400))
        let active = snapshot(reset: now.addingTimeInterval(3600), used: 0.1)
        let unknown = snapshot(reset: nil)
        #expect(RosterUrgency.level(for: expired, at: now, isCurrent: true) == .none)
        #expect(RosterUrgency.level(for: active, at: now, isCurrent: false) == .none)
        #expect(RosterUrgency.level(for: unknown, at: now, isCurrent: false) == .none)
    }

    @Test func codexDoesNotInventAnUpcomingReset() {
        let account = snapshot(provider: .openai, reset: now.addingTimeInterval(-27 * 86400))
        #expect(RosterUrgency.level(for: account, at: now, isCurrent: false) == .ready)
        #expect(RosterUrgency.level(for: account, at: now.addingTimeInterval(30 * 86400), isCurrent: false) == .ready)
    }

    @Test func sessionResetDoesNotMakeTheWholeWeeklyAccountUnused() {
        var account = snapshot(reset: now.addingTimeInterval(3 * 86400), used: 0.5)
        account.groups.append(UsageGroup(name: "5-Hour Session", limits: [
            UsageLimit(name: "5-Hour Session", percentUsed: 1,
                       resetAt: now.addingTimeInterval(-3600), windowType: .fiveHour)
        ]))
        #expect(RosterUrgency.level(for: account, at: now, isCurrent: false) == .none)
    }

    @Test func anExhaustedSessionPreventsReadyHighlight() {
        var account = snapshot(reset: now.addingTimeInterval(-6.9 * 86400))
        account.groups.append(UsageGroup(name: "5-Hour Session", limits: [
            UsageLimit(name: "5-Hour Session", percentUsed: 1,
                       resetAt: now.addingTimeInterval(3600), windowType: .fiveHour)
        ]))
        #expect(RosterUrgency.level(for: account, at: now, isCurrent: false) == .none)
    }
}
