import Foundation
import LLMitsCore

var failures = 0

func expect(_ cond: Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    if !cond {
        failures += 1
        fputs("FAIL \(file):\(line) \(message)\n", stderr)
    }
}

func fixture(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Grok

do {
    let credits = fixture([
        "config": [
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": "2026-08-07T10:54:53.882335+00:00",
                "end": "2026-08-14T10:54:53.882335+00:00"
            ],
            "creditUsagePercent": 1.0,
            "onDemandCap": ["val": 0],
            "onDemandUsed": ["val": 0],
            "productUsage": [
                ["product": "GrokBuild", "usagePercent": 1.0]
            ],
            "isUnifiedBillingUser": true,
            "prepaidBalance": ["val": 0],
            "billingPeriodStart": "2026-08-07T10:54:53.882335+00:00",
            "billingPeriodEnd": "2026-08-14T10:54:53.882335+00:00"
        ]
    ])
    let plain = fixture([
        "config": [
            "monthlyLimit": ["val": 0],
            "used": ["val": 0],
            "onDemandCap": ["val": 0],
            "billingPeriodStart": "2026-08-01T00:00:00+00:00",
            "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
        ]
    ])
    let groups = try GrokBillingParser.parse(credits: credits, plain: plain)
    let limits = groups[0].limits
    expect(limits.contains { $0.windowType == .weekly }, "expected weekly window")
    expect(!limits.contains { $0.windowType == .monthly && $0.name == "Build Credits" }, "must not label weekly pool as monthly Build Credits")
    let weekly = limits.first { $0.name == "Weekly Usage" }
    expect(weekly?.percentUsed == 1.0, "weekly percent")
}

do {
    // Overage is reported as 2.0 (= 200% of the pool), not 2%.
    let credits = fixture([
        "config": [
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-08-14T10:54:53Z"],
            "creditUsagePercent": 2.0,
            "isUnifiedBillingUser": true,
            "productUsage": [["product": "GrokBuild", "usagePercent": 2.0]]
        ]
    ])
    let weekly = try GrokBillingParser.parse(credits: credits, plain: fixture(["config": [:]]))[0]
        .limits.first { $0.name == "Weekly Usage" }
    expect(weekly?.percentUsed == 1.0, "overage fraction caps at 100%, is not treated as 2%")
    expect(weekly?.resetAt != nil, "weekly resetAt")
    if let reset = weekly?.resetAt {
        expect(Calendar.current.component(.day, from: reset) == 14, "reset day")
        expect(Calendar.current.component(.month, from: reset) == 8, "reset month")
    }
}

do {
    let credits = fixture([
        "config": [
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "end": "2026-08-14T10:54:53.882335+00:00"
            ],
            "creditUsagePercent": 0.6,
            "isUnifiedBillingUser": true,
            "productUsage": [
                ["product": "GrokBuild", "usagePercent": 0.4],
                ["product": "GrokChat", "usagePercent": 0.2]
            ]
        ]
    ])
    let names = try GrokBillingParser.parse(credits: credits, plain: fixture(["config": [:]]))[0].limits.map(\.name)
    expect(names.contains("Weekly Usage"), "pool row")
    expect(names.contains("Build"), "build share")
    expect(names.contains("Chat"), "chat share")
}

do {
    let credits = fixture([
        "config": [
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_MONTHLY",
                "end": "2026-09-01T00:00:00+00:00"
            ],
            "creditUsagePercent": 0.25
        ]
    ])
    let plain = fixture([
        "config": [
            "monthlyLimit": ["val": 2000],
            "used": ["val": 500],
            "billingPeriodEnd": "2026-09-01T00:00:00+00:00"
        ]
    ])
    let creditsLimit = try GrokBillingParser.parse(credits: credits, plain: plain)[0].limits.first { $0.name == "Build Credits" }
    expect(creditsLimit?.percentUsed == 0.25, "legacy percent")
    expect(creditsLimit?.windowType == .monthly, "legacy monthly")
    expect(creditsLimit?.detail == "500 / 2000", "legacy detail")
    expect(creditsLimit?.resetAt != nil, "legacy resetAt")
}

do {
    let credits = fixture([
        "config": [
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-08-14T10:54:53Z"],
            "creditUsagePercent": 1.0,
            "isUnifiedBillingUser": true,
            "prepaidBalance": ["val": 12],
            "onDemandCap": ["val": 50],
            "onDemandUsed": ["val": 10]
        ]
    ])
    let limits = try GrokBillingParser.parse(credits: credits, plain: fixture(["config": [:]]))[0].limits
    expect(limits.contains { $0.name == "Extra Credits" && $0.detail == "12 remaining" }, "prepaid")
    expect(limits.contains { $0.name == "On-Demand" && $0.percentUsed == 0.2 }, "on-demand")
}

// MARK: - Kimi

do {
    let json: [String: Any] = [
        "limits": [[
            "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
            "detail": [
                "limit": "100",
                "remaining": "100",
                "resetTime": "2026-08-13T00:00:42.846726Z"
            ]
        ]],
        "usage": [
            "limit": "100",
            "used": "25",
            "remaining": "75",
            "resetTime": "2026-08-14T10:00:42.846726Z"
        ]
    ]
    let groups = KimiUsageParser.parse(json)
    let fiveH = groups.first { $0.name == "Kimi — 5h" }?.limits.first
    expect(fiveH?.percentUsed == 0, "5h unused")
    expect(fiveH?.resetAt != nil, "5h resetAt even when unused")
    expect(fiveH?.windowType == .fiveHour, "5h type")
    expect(fiveH?.resetDetail(at: Date(timeIntervalSince1970: 1_786_567_979)) != nil, "5h countdown")

    let weekly = groups.first { $0.name == "Kimi — Weekly" }?.limits.first
    expect(abs((weekly?.percentUsed ?? -1) - 0.25) < 0.001, "weekly 25%")
    expect(weekly?.windowType == .weekly, "weekly type")
    expect(weekly?.resetAt != nil, "weekly resetAt")
    expect(weekly?.detail == "25 / 100", "weekly counts")
}

do {
    let now = Date()
    let reset = now.addingTimeInterval(90 * 60)
    let limit = UsageLimit(name: "Kimi — Weekly", percentUsed: 0.25, resetAt: reset, windowType: .weekly)
    let later = now.addingTimeInterval(50 * 60)
    expect(limit.resetDetail(at: now) != limit.resetDetail(at: later), "countdown ticks locally")
    expect(limit.resetDetail(at: now)?.contains("1h") == true, "90m shows 1h")
    expect(limit.resetDetail(at: later)?.contains("40m") == true, "40m remaining")
}

do {
    let limit = UsageLimit(
        name: "Kimi — 5h",
        percentUsed: 0.8,
        resetAt: Date().addingTimeInterval(-10),
        windowType: .fiveHour
    )
    expect(limit.percentUsed(at: Date()) == 0, "expired window zeros locally")
    expect(limit.resetDetail(at: Date()) == nil, "expired countdown hidden")
}

do {
    let group = KimiUsageParser.parseRateWindow([
        "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
        "detail": ["limit": "100", "resetTime": "2099-01-01T00:00:00Z"]
    ])
    expect(group?.limits[0].percentUsed == 0, "omitted used = 0")
    expect(group?.limits[0].resetAt != nil, "omitted used still has resetAt")
}

// MARK: - Snapshot store

do {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmits-test-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = UsageSnapshotStore(dbURL: url)
    let accountID = UUID()
    let resetAt = Date(timeIntervalSince1970: 1_786_656_000)
    store.save(UsageSnapshot(
        accountID: accountID,
        provider: .kimi,
        fetchedAt: Date(timeIntervalSince1970: 1_786_567_000),
        identity: "d9cv5vbmrb776acf3680",
        groups: [
            UsageGroup(name: "Kimi — Weekly", limits: [
                UsageLimit(
                    name: "Kimi — Weekly",
                    percentUsed: 0.25,
                    detail: "25 / 100",
                    resetAt: resetAt,
                    windowType: .weekly
                )
            ])
        ],
        error: nil
    ))
    let loaded = store.load(accountID: accountID)
    expect(loaded?.provider == .kimi, "snapshot provider")
    expect(loaded?.identity == "d9cv5vbmrb776acf3680", "snapshot identity")
    expect(loaded?.groups[0].limits[0].percentUsed == 0.25, "snapshot percent")
    expect(loaded?.groups[0].limits[0].resetAt == resetAt, "snapshot resetAt")
    expect(store.loadAll()[accountID]?.groups.count == 1, "loadAll")
}

// MARK: - Dates

expect(TimeFormatter.parseISO8601("2026-08-14T10:54:53.882335+00:00") != nil, "grok offset date")
expect(TimeFormatter.parseISO8601("2026-08-14T10:00:42.846726Z") != nil, "kimi zulu date")
expect(TimeFormatter.windowType(fromPeriodType: "USAGE_PERIOD_TYPE_WEEKLY") == .weekly, "weekly type")
expect(TimeFormatter.windowType(fromPeriodType: "USAGE_PERIOD_TYPE_MONTHLY") == .monthly, "monthly type")

if failures > 0 {
    fputs("\(failures) check(s) failed\n", stderr)
    exit(1)
}
print("All LLMitsCheck assertions passed")
