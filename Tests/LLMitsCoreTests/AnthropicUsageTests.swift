import Foundation
import Testing
@testable import LLMitsCore

struct AnthropicUsageTests {
    private let reset = "2099-01-04T12:00:00Z"

    private func parse(_ payload: [String: Any]) throws -> [UsageGroup] {
        try AnthropicService().parseUsageResponse(JSONSerialization.data(withJSONObject: payload))
    }

    @Test(arguments: [false, true])
    func legacyWeeklyOnlyAllowsMissingOrNullSession(nullSession: Bool) throws {
        var payload: [String: Any] = [
            "seven_day": ["utilization": 25.0, "resets_at": reset]
        ]
        if nullSession { payload["five_hour"] = NSNull() }
        let groups = try parse(payload)
        #expect(groups.flatMap(\.limits).map(\.windowType) == [.weekly])
        let pills = RosterPills.pills(for: .anthropic, groups: groups)
        #expect(pills.map(\.label) == ["Wk"])
        #expect(pills.first?.limit?.remainingPercentage(at: Date()) == 75)
    }

    @Test(arguments: [false, true])
    func modernSessionPresenceIsPerAccount(hasSession: Bool) throws {
        var limits: [[String: Any]] = [
            ["kind": "weekly_all", "group": "weekly", "percent": 25, "resets_at": reset],
            ["kind": "weekly_scoped", "group": "weekly", "percent": 50, "resets_at": reset,
             "scope": ["model": ["display_name": "Fable"]]]
        ]
        if hasSession {
            limits.append(["kind": "session", "group": "session", "percent": 80, "resets_at": reset])
        }
        // Modern limits are authoritative even if a legacy field is also sent.
        let groups = try parse([
            "limits": limits,
            "five_hour": ["utilization": 100.0, "resets_at": reset]
        ])
        let pills = RosterPills.pills(for: .anthropic, groups: groups)
        #expect(pills.map(\.label) == (hasSession ? ["Wk", "Fable", "5h"] : ["Wk", "Fable"]))
        #expect(groups.flatMap(\.limits).filter { $0.windowType == .fiveHour }.count == (hasSession ? 1 : 0))
    }

    @Test func legacyAccountWithSessionStillShowsIt() throws {
        let groups = try parse([
            "seven_day": ["utilization": 25.0, "resets_at": reset],
            "five_hour": ["utilization": 80.0, "resets_at": reset]
        ])
        let pills = RosterPills.pills(for: .anthropic, groups: groups)
        #expect(pills.map(\.label) == ["Wk", "5h"])
        #expect(pills.last?.limit?.remainingPercentage(at: Date()) == 20)
    }
}
