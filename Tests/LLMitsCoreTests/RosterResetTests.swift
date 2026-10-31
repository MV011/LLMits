import Foundation
import Testing
@testable import LLMitsCore

struct RosterResetTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func group(_ provider: Provider, type: UsageLimit.WindowType, resetAt: Date?) -> UsageGroup {
        let name = type == .weekly
            ? (provider == .anthropic ? "Weekly Overall" : "Codex — Weekly")
            : (provider == .anthropic ? "5-Hour Session" : "Codex — 5h")
        return UsageGroup(name: name, limits: [
            UsageLimit(name: name, percentUsed: 0.25, resetAt: resetAt, windowType: type)
        ])
    }

    @Test(arguments: ["anthropic", "openai"])
    func bothWindowsShowResetCountdowns(providerName: String) throws {
        let provider = try #require(Provider(rawValue: providerName))
        let groups = [
            group(provider, type: .fiveHour, resetAt: now.addingTimeInterval(90 * 60)),
            group(provider, type: .weekly, resetAt: now.addingTimeInterval(3 * 86400))
        ]
        let pills = RosterPills.pills(for: provider, groups: groups, at: now)
        let session = try #require(pills.first { $0.label == "5h" })
        let weekly = try #require(pills.first { $0.label == "Wk" })
        #expect(pills.count == 2)
        #expect(session.kind == .remainingPercent)
        #expect(session.limit?.remainingPercentage(at: now) == 75)
        #expect(session.resetDescription(at: now) == "resets in 1h 30m")
        #expect(weekly.resetDescription(at: now) == "resets in 3d 0h")
        let later = now.addingTimeInterval(50 * 60)
        #expect(session.resetDescription(at: later) == "resets in 40m")
        #expect(weekly.resetDescription(at: later) == "resets in 2d 23h")
        #expect(session.limit?.remainingPercentage(at: later) == 75)
    }

    @Test(arguments: ["anthropic", "openai"], ["5-hour", "Weekly"])
    func expiredSnapshotShowsReadinessWithoutChangingStoredUsage(providerName: String, windowName: String) throws {
        let provider = try #require(Provider(rawValue: providerName))
        let type = try #require(UsageLimit.WindowType(rawValue: windowName))
        let resetAt = now.addingTimeInterval(60)
        let groups = [group(provider, type: type, resetAt: resetAt)]
        let before = try #require(RosterPills.pills(for: provider, groups: groups, at: now).first)
        #expect(before.resetDescription(at: now.addingTimeInterval(30)) == "resets in <1m")
        let expired = try #require(RosterPills.pills(for: provider, groups: groups, at: resetAt).first)
        #expect(expired.kind == .resetPassed)
        if provider == .anthropic && type == .weekly {
            #expect(expired.resetDescription(at: resetAt) == "ready · next reset in 7d 0h (est.)")
            #expect(expired.nextReset(at: resetAt) == resetAt.addingTimeInterval(7 * 86400))
        } else {
            #expect(expired.resetDescription(at: resetAt) == "ready · refresh to confirm")
            #expect(expired.nextReset(at: resetAt) == nil)
        }
        #expect(expired.limit?.percentUsed == 0.25)
        #expect(expired.limit?.remainingPercentage(at: resetAt) == 100)
        #expect(expired.resetDateDescription(at: resetAt) != nil)
        #expect(expired.resetHelp(at: resetAt).contains("estimated"))
    }

    @Test(arguments: ["anthropic", "openai"], ["5-hour", "Weekly"])
    func missingResetIsExplicit(providerName: String, windowName: String) throws {
        let provider = try #require(Provider(rawValue: providerName))
        let type = try #require(UsageLimit.WindowType(rawValue: windowName))
        let groups = [group(provider, type: type, resetAt: nil)]
        let pill = try #require(RosterPills.pills(for: provider, groups: groups, at: now).first)
        #expect(pill.kind == .remainingPercent)
        #expect(pill.resetDescription(at: now) == "reset time unavailable")
        #expect(pill.nextReset(at: now) == nil)
        #expect(pill.resetDateDescription(at: now) == nil)
    }

    @Test func codexSessionDoesNotRequireWeeklyData() {
        let groups = [group(.openai, type: .fiveHour, resetAt: now.addingTimeInterval(3600))]
        let pills = RosterPills.pills(for: .openai, groups: groups, at: now)
        #expect(pills.map(\.label) == ["5h"])
        #expect(pills.first?.resetDescription(at: now) == "resets in 1h 0m")
    }

    @Test func weeklyOnlyAccountDoesNotInventSession() {
        let groups = [group(.openai, type: .weekly, resetAt: now.addingTimeInterval(3 * 86400))]
        #expect(RosterPills.pills(for: .openai, groups: groups, at: now).map(\.label) == ["Wk"])
    }

    @Test func claudeScopedWeeklyKeepsItsOwnReset() throws {
        let groups = [
            group(.anthropic, type: .weekly, resetAt: now.addingTimeInterval(3 * 86400)),
            UsageGroup(name: "Weekly — Fable", limits: [
                UsageLimit(name: "Weekly — Fable", percentUsed: 0.5,
                           resetAt: now.addingTimeInterval(2 * 86400), windowType: .weekly)
            ])
        ]
        let pills = RosterPills.pills(for: .anthropic, groups: groups, at: now)
        let fable = try #require(pills.first { $0.label == "Fable" })
        #expect(fable.resetDescription(at: now) == "resets in 2d 0h")
        #expect(pills.first?.resetDescription(at: now) == "resets in 3d 0h")
    }

    @Test func legacyWeeklyStaysWeeklyNearAndAfterReset() throws {
        let resetAt = now.addingTimeInterval(6 * 86400)
        let groups = [group(.openai, type: .fiveHour, resetAt: resetAt)]
        let nearReset = resetAt.addingTimeInterval(-3600)
        let pills = RosterPills.pills(for: .openai, groups: groups, at: nearReset, fetchedAt: now)
        #expect(pills.map(\.label) == ["Wk"])
        #expect(pills.first?.resetDescription(at: nearReset) == "resets in 1h 0m")
        let expired = RosterPills.pills(for: .openai, groups: groups, at: resetAt, fetchedAt: now)
        #expect(expired.map(\.label) == ["Wk"])
        #expect(expired.first?.kind == .resetPassed)
        #expect(expired.first?.nextReset(at: resetAt) == nil)
    }

    @Test func idleClaudeAccountKeepsWeeklyCadenceAcrossManyCycles() throws {
        let recorded = now.addingTimeInterval(-24 * 86400)
        let groups = [group(.anthropic, type: .weekly, resetAt: recorded)]
        let pill = try #require(RosterPills.pills(for: .anthropic, groups: groups, at: now).first)
        let next = now.addingTimeInterval(4 * 86400)
        #expect(pill.nextReset(at: now) == next)
        #expect(pill.resetDescription(at: now) == "ready · next reset in 4d 0h (est.)")
        #expect(pill.nextReset(at: next) == next.addingTimeInterval(7 * 86400))
        #expect(pill.limit?.resetAt == recorded)
        #expect(pill.resetDateDescription(at: now)?.hasPrefix("Next:") == true)
    }

    @Test func codexAndSessionsKeepTheRecordedReadyDate() throws {
        let recorded = now.addingTimeInterval(-24 * 86400)
        let groups = [group(.openai, type: .weekly, resetAt: recorded)]
        let pill = try #require(RosterPills.pills(for: .openai, groups: groups, at: now).first)
        #expect(pill.nextReset(at: now) == nil)
        #expect(pill.resetDateDescription(at: now)?.hasPrefix("Ready since:") == true)
        #expect(pill.limit?.resetAt == recorded)
    }
}
