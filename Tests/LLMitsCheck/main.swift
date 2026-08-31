import Foundation
import LLMitsCore
import SQLite3

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
                "end": "2026-10-14T10:54:53.882335+00:00"
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
            "billingPeriodEnd": "2026-10-14T10:54:53.882335+00:00"
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
    expect(abs((weekly?.percentUsed ?? -1) - 0.01) < 0.0001, "1.0 from API is 1% used")
}

do {
    // Live SuperGrok Heavy payload: 2.0 means 2% of the weekly pool, not 200%.
    let credits = fixture([
        "config": [
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-14T10:54:53Z"],
            "creditUsagePercent": 2.0,
            "isUnifiedBillingUser": true,
            "productUsage": [["product": "GrokBuild", "usagePercent": 2.0]]
        ]
    ])
    let weekly = try GrokBillingParser.parse(credits: credits, plain: fixture(["config": [:]]))[0]
        .limits.first { $0.name == "Weekly Usage" }
    expect(abs((weekly?.percentUsed ?? -1) - 0.02) < 0.0001, "2.0 from API is 2% used")
    expect(weekly?.detail?.contains("2% used") == true, "detail shows 2% used")
    expect(weekly?.resetAt != nil, "weekly resetAt")
    if let reset = weekly?.resetAt {
        expect(Calendar.current.component(.day, from: reset) == 14, "reset day")
        expect(Calendar.current.component(.month, from: reset) == 10, "reset month")
    }
}

do {
    let credits = fixture([
        "config": [
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "end": "2026-10-14T10:54:53.882335+00:00"
            ],
            "creditUsagePercent": 60.0,
            "isUnifiedBillingUser": true,
            "productUsage": [
                ["product": "GrokBuild", "usagePercent": 40.0],
                ["product": "GrokChat", "usagePercent": 20.0]
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
            "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY", "end": "2026-10-14T10:54:53Z"],
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
                "resetTime": "2026-10-13T00:00:42.846726Z"
            ]
        ]],
        "usage": [
            "limit": "100",
            "used": "25",
            "remaining": "75",
            "resetTime": "2026-10-14T10:00:42.846726Z"
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

func makeSnapshot(
    accountID: UUID = UUID(),
    provider: Provider,
    identity: String?,
    fetchedAt: Date = Date(timeIntervalSince1970: 1_786_567_000),
    groups: [UsageGroup],
    error: String? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        accountID: accountID,
        provider: provider,
        fetchedAt: fetchedAt,
        identity: identity,
        groups: groups,
        error: error
    )
}

func weeklyGroup(name: String, used: Double, resetAt: Date? = Date(timeIntervalSince1970: 1_787_000_000)) -> UsageGroup {
    UsageGroup(name: name, limits: [
        UsageLimit(name: name, percentUsed: used, resetAt: resetAt, windowType: .weekly)
    ])
}

func fiveHourGroup(used: Double, resetAt: Date?) -> UsageGroup {
    UsageGroup(name: "5-Hour Session", limits: [
        UsageLimit(name: "5-Hour Session", percentUsed: used, resetAt: resetAt, windowType: .fiveHour)
    ])
}

// MARK: - Identity snapshots

do {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmits-ident-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = UsageSnapshotStore(dbURL: url)
    let accountID = UUID()
    let groupsA = [weeklyGroup(name: "Weekly Overall", used: 0.4)]
    let groupsB = [weeklyGroup(name: "Weekly Overall", used: 0.9)]

    store.save(makeSnapshot(
        accountID: accountID,
        provider: .anthropic,
        identity: "a@example.com",
        groups: groupsA
    ))
    store.save(makeSnapshot(
        accountID: accountID,
        provider: .anthropic,
        identity: "b@example.com",
        fetchedAt: Date(timeIntervalSince1970: 1_786_567_100),
        groups: groupsB
    ))

    let live = store.load(accountID: accountID)
    expect(live?.identity == "b@example.com", "live row follows latest identity")
    expect(live?.groups[0].limits[0].percentUsed == 0.9, "live row overwritten")

    let identities = store.loadIdentities(providers: [.anthropic])
    expect(identities.count == 2, "both identities kept")
    let a = identities.first { $0.identity == "a@example.com" }
    let b = identities.first { $0.identity == "b@example.com" }
    expect(a?.groups[0].limits[0].percentUsed == 0.4, "identity A percentages unchanged")
    expect(b?.groups[0].limits[0].percentUsed == 0.9, "identity B stored")
}

do {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmits-ident-err-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = UsageSnapshotStore(dbURL: url)
    let accountID = UUID()
    store.save(makeSnapshot(
        accountID: accountID,
        provider: .anthropic,
        identity: "a@example.com",
        groups: [weeklyGroup(name: "Weekly Overall", used: 0.4)]
    ))
    store.save(makeSnapshot(
        accountID: accountID,
        provider: .anthropic,
        identity: "a@example.com",
        groups: [],
        error: "401"
    ))
    let loaded = store.loadIdentities(providers: [.anthropic]).first
    expect(loaded?.groups[0].limits[0].percentUsed == 0.4, "empty-group error does not clobber identity cache")
    expect(store.load(accountID: accountID)?.error == "401", "live row still records the error")
}

do {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmits-ident-del-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = UsageSnapshotStore(dbURL: url)
    store.save(makeSnapshot(
        provider: .anthropic,
        identity: "gone@example.com",
        groups: [weeklyGroup(name: "Weekly Overall", used: 0.1)]
    ))
    store.deleteIdentity(provider: .anthropic, identity: "gone@example.com")
    expect(store.loadIdentities(providers: [.anthropic]).isEmpty, "deleteIdentity removes roster row")
}

do {
    // Old-schema DB: snapshots only. Opening the store must backfill identity_snapshots.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("llmits-ident-bf-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    var db: OpaquePointer?
    expect(sqlite3_open(url.path, &db) == SQLITE_OK, "open old-schema sqlite")
    let create = """
    CREATE TABLE snapshots (
        account_id TEXT PRIMARY KEY,
        provider TEXT NOT NULL,
        fetched_at REAL NOT NULL,
        payload TEXT NOT NULL
    );
    """
    expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK, "create old snapshots table")
    let payload = """
    {"accountID":"C4750971-AA89-4BCF-9EC3-6394BAE84A01","error":null,"fetchedAt":"2026-08-30T11:21:20Z","groups":[{"limits":[{"detail":null,"name":"Weekly Overall","percentDisplay":"remaining","percentUsed":0.6,"resetAt":"2026-09-04T17:00:00Z","windowType":"Weekly"}],"name":"Weekly Overall"}],"identity":"heimanncovers@gmail.com","provider":"anthropic"}
    """
    let insert = """
    INSERT INTO snapshots (account_id, provider, fetched_at, payload)
    VALUES ('C4750971-AA89-4BCF-9EC3-6394BAE84A01', 'anthropic', 1788088880, '\(payload)');
    """
    expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK, "insert legacy snapshot")
    sqlite3_close(db)

    let store = UsageSnapshotStore(dbURL: url)
    let identities = store.loadIdentities(providers: [.anthropic])
    expect(identities.count == 1, "backfill one identity")
    expect(identities.first?.identity == "heimanncovers@gmail.com", "backfill identity email")
    expect(identities.first?.groups[0].limits[0].percentUsed == 0.6, "backfill percent")
}

// MARK: - Roster pills

do {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let resetWeek = now.addingTimeInterval(3 * 86400)
    let groups = [
        fiveHourGroup(used: 0, resetAt: nil),
        weeklyGroup(name: "Weekly Overall", used: 0.6, resetAt: resetWeek),
        weeklyGroup(name: "Weekly — Fable", used: 0.25, resetAt: resetWeek)
    ]
    let pills = RosterPills.pills(for: .anthropic, groups: groups, at: now)
    expect(pills.contains { $0.label == "Wk" && $0.kind == .remainingPercent }, "claude weekly pill")
    expect(pills.contains { $0.label == "Fable" && $0.kind == .remainingPercent }, "claude fable pill")
    expect(!pills.contains { $0.kind == .fiveHourExhausted }, "5h hidden when unused")
    let wk = pills.first { $0.label == "Wk" }
    expect(wk?.limit?.percentRemaining(at: now) == 0.4, "wk remaining 40%")
}

do {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let resetFive = now.addingTimeInterval(90 * 60)
    let groups = [
        fiveHourGroup(used: 1.0, resetAt: resetFive),
        weeklyGroup(name: "Weekly Overall", used: 0.8, resetAt: now.addingTimeInterval(86400))
    ]
    let pills = RosterPills.pills(for: .anthropic, groups: groups, at: now)
    expect(pills.contains { $0.kind == .fiveHourExhausted }, "5h shown when exhausted")
    let later = now.addingTimeInterval(2 * 3600)
    let afterReset = RosterPills.pills(for: .anthropic, groups: groups, at: later)
    expect(!afterReset.contains { $0.kind == .fiveHourExhausted }, "5h hidden after local reset")
}

do {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let weeklyReset = now.addingTimeInterval(6 * 86400)
    let groups = [
        UsageGroup(name: "Codex — 5h", limits: [
            UsageLimit(name: "Codex 5h Limit", percentUsed: 0.09, resetAt: weeklyReset, windowType: .fiveHour)
        ]),
        UsageGroup(name: "GPT-5.3-Codex-Spark — Weekly", limits: [
            UsageLimit(name: "GPT-5.3-Codex-Spark Weekly", percentUsed: 0, resetAt: weeklyReset, windowType: .weekly)
        ])
    ]
    let pills = RosterPills.pills(for: .openai, groups: groups, at: now)
    expect(pills.contains { $0.label == "Wk" && $0.kind == .remainingPercent }, "codex weekly from long-reset primary")
    expect(pills.contains { $0.kind == .resetCountdown }, "codex reset timer")
    expect(!pills.contains { $0.label.lowercased().contains("spark") }, "spark ignored")
    let wk = pills.first { $0.label == "Wk" }
    expect(abs((wk?.limit?.percentUsed ?? -1) - 0.09) < 0.0001, "codex uses main window not spark")
}

do {
    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let groups = [
        UsageGroup(name: "Codex — 5h", limits: [
            UsageLimit(name: "Codex 5h Limit", percentUsed: 0.2, resetAt: now.addingTimeInterval(3 * 3600), windowType: .fiveHour)
        ]),
        UsageGroup(name: "Codex — Weekly", limits: [
            UsageLimit(name: "Codex Weekly", percentUsed: 0.55, resetAt: now.addingTimeInterval(4 * 86400), windowType: .weekly)
        ])
    ]
    let pills = RosterPills.pills(for: .openai, groups: groups, at: now)
    let wk = pills.first { $0.label == "Wk" }
    expect(abs((wk?.limit?.percentUsed ?? -1) - 0.55) < 0.0001, "prefer real weekly group")
}

do {
    let fiveDays: TimeInterval = 5.0 * 86400 + 12.0 * 3600 + 3.0 * 60
    let compact = TimeFormatter.formatCompactRemaining(fiveDays)
    expect(compact == "5d 12h", "compact days drop minutes")
    expect(TimeFormatter.formatCompactRemaining(5400.0) == "1h 30m", "compact hours")
    expect(TimeFormatter.formatCompactRemaining(45.0) == "<1m", "compact sub-minute")
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
