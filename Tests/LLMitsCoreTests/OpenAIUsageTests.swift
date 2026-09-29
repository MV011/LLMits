import Foundation
import Testing
@testable import LLMitsCore

struct OpenAIUsageTests {
    private let service = OpenAIService()
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func parse(_ object: [String: Any]) throws -> [UsageGroup] {
        try service.parseUsageResponse(JSONSerialization.data(withJSONObject: object))
    }

    @Test func weeklyAllowanceInPrimaryWindow() throws {
        let groups = try parse([
            "rate_limit": [
                "primary_window": ["used_percent": 75, "limit_window_seconds": 604800,
                                   "reset_at": now.addingTimeInterval(4 * 86400).timeIntervalSince1970],
                "secondary_window": NSNull()
            ],
            "credits": ["balance": "0", "has_credits": false, "unlimited": false]
        ])
        let weekly = try #require(groups.first { $0.name == "Codex — Weekly" }?.limits.first)
        #expect(weekly.windowType == .weekly)
        #expect(weekly.percentUsed == 0.75)
        #expect(weekly.percentRemaining(at: now) == 0.25)
        #expect(!groups.flatMap(\.limits).contains { $0.windowType == .fiveHour })
        let pills = RosterPills.pills(for: .openai, groups: groups, at: now)
        #expect(pills.first { $0.label == "Wk" }?.limit == weekly)
        let balance = try #require(groups.first { $0.name == "Credits" }?.limits.first)
        #expect(balance.percentDisplay == .none)
        #expect(balance.percentUsed == 0)
        #expect(balance.detail == "Balance: 0")
    }

    @Test func bothWindowsUseReportedDuration() throws {
        let groups = try parse([
            "rate_limit": [
                "primary_window": ["used_percent": "76", "limit_window_seconds": "604800",
                                   "reset_at": String(now.addingTimeInterval(86400).timeIntervalSince1970)],
                "secondary_window": ["used_percent": 20.5, "limit_window_seconds": 18000,
                                     "reset_after_seconds": "3600"]
            ],
            "additional_rate_limits": [[
                "limit_name": "Spark",
                "rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 604800]]
            ]]
        ])
        #expect(groups[0].limits[0].windowType == .weekly)
        #expect(groups[0].limits[0].percentUsed == 0.76)
        #expect(groups[0].limits[0].resetAt == now.addingTimeInterval(86400))
        #expect(groups[1].limits[0].windowType == .fiveHour)
        #expect(groups[1].limits[0].percentUsed == 0.205)
        let reset = try #require(groups[1].limits[0].resetAt)
        #expect(abs(reset.timeIntervalSinceNow - 3600) < 5)
        #expect(RosterPills.pills(for: .openai, groups: groups, at: now).first?.limit?.percentUsed == 0.76)
    }

    @Test func legacyWindowsKeepTheirLabels() throws {
        let groups = try parse(["rate_limit": [
            "primary_window": ["used_percent": 20],
            "secondary_window": ["used_percent": 55]
        ]])
        #expect(groups.map(\.name) == ["Codex — 5h", "Codex — Weekly"])
        #expect(groups.map { $0.limits[0].windowType } == [.fiveHour, .weekly])
    }

    @Test func unknownDurationDoesNotInventFiveHourWindow() throws {
        let groups = try parse(["rate_limit": [
            "primary_window": ["used_percent": 0, "limit_window_seconds": 7200]
        ]])
        #expect(groups[0].limits[0].windowType == .unknown)
        #expect(groups[0].name == "Codex — Primary")
    }

    @Test(arguments: ["missing", "not-a-number", "NaN", "Infinity"])
    func invalidPercentagesDoNotBecomeZero(value: String) {
        var window: [String: Any] = ["limit_window_seconds": 604800]
        if value != "missing" { window["used_percent"] = value }
        #expect(throws: ServiceError.self) {
            try parse(["rate_limit": ["primary_window": window]])
        }
    }

    @Test(arguments: [-10.0, 0.0, 75.0, 150.0])
    func percentagesStayWithinBounds(value: Double) throws {
        let groups = try parse(["rate_limit": ["primary_window": ["used_percent": value]]])
        #expect(groups[0].limits[0].percentUsed == min(max(value / 100, 0), 1))
    }

    @Test func emptyResponseIsAnError() {
        #expect(throws: ServiceError.self) { try parse([:]) }
        #expect(throws: ServiceError.self) { try parse(["credits": [:]]) }
    }

    @Test func creditsAreBalancesWithoutInventedPercentages() throws {
        let groups = try parse(["credits": ["balance": 125.5]])
        #expect(groups[0].limits[0].detail == "Balance: 125.5")
        #expect(groups[0].limits[0].percentDisplay == .none)
        let unlimited = try parse(["credits": ["unlimited": true]])
        #expect(unlimited[0].limits[0].detail == "Unlimited")
    }

    @Test func malformedEpochFallsBackToRelativeReset() throws {
        let groups = try parse(["rate_limit": ["primary_window": [
            "used_percent": 75, "reset_at": NSNull(), "reset_after_seconds": 3600
        ]]])
        let reset = try #require(groups[0].limits[0].resetAt)
        #expect(abs(reset.timeIntervalSinceNow - 3600) < 5)
    }

    @Test func requestRoutesToSelectedAccount() {
        let request = OpenAIService.usageRequest(accessToken: "synthetic-token", accountID: "synthetic-account")
        #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "synthetic-account")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    private func token(accountID: String) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID]
        ]).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "synthetic.\(payload).signature"
    }

    @Test func accountRoutingStaysPairedWithItsToken() throws {
        let selected = try token(accountID: "selected-account")
        let auth: [String: Any] = ["tokens": ["access_token": selected, "account_id": "selected-workspace"]]
        #expect(OpenAIService.accountID(for: selected, authJSON: auth) == "selected-workspace")
        let other = try token(accountID: "other-account")
        #expect(OpenAIService.accountID(for: other, authJSON: auth) == "other-account")
        #expect(OpenAIService.accountID(for: selected, authJSON: nil) == "selected-account")
        #expect(OpenAIService.accountID(for: "manual-opaque-token", authJSON: auth) == nil)
    }

    @Test func balanceDisplaySurvivesSnapshotRoundTrip() throws {
        let groups = try parse(["credits": ["balance": "0"]])
        let restored = try JSONDecoder().decode([UsageGroup].self, from: JSONEncoder().encode(groups))
        #expect(restored == groups)
        #expect(restored[0].limits[0].percentDisplay == .none)
    }

    @Test(arguments: [0, 29, 55, 75, 76, 77, 100])
    func displayedRemainderMatchesReportedUsage(used: Int) {
        let limit = UsageLimit(name: "Codex Weekly", percentUsed: Double(used) / 100, windowType: .weekly)
        #expect(limit.remainingPercentage(at: now) == 100 - used)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LLMITS_OPENAI_LIVE_CHECK"] == "1"))
    func liveUsageFromInstalledCodexCredentials() async throws {
        let groups = try await service.fetchUsage(token: "mock")
        #expect(groups.contains { $0.name.hasPrefix("Codex —") })
        for group in groups where group.name.hasPrefix("Codex —") {
            for limit in group.limits {
                print("Live OpenAI: \(group.name), \(Int((limit.percentUsed * 100).rounded()))% used, \(limit.remainingPercentage(at: Date()))% left")
            }
        }
    }
}
