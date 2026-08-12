import Foundation
import SQLite3

/// Last-known-good usage snapshot per account.
///
/// The dashboard hydrates from this on launch so the popover shows the last
/// synced API status immediately, and live countdowns can tick from stored
/// `resetAt` timestamps without waiting for a network round-trip.
public struct UsageSnapshot: Codable, Equatable {
    public var accountID: UUID
    public var provider: Provider
    public var fetchedAt: Date
    public var identity: String?
    public var groups: [UsageGroup]
    public var error: String?

    public init(
        accountID: UUID,
        provider: Provider,
        fetchedAt: Date,
        identity: String?,
        groups: [UsageGroup],
        error: String?
    ) {
        self.accountID = accountID
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.identity = identity
        self.groups = groups
        self.error = error
    }
}

public final class UsageSnapshotStore: @unchecked Sendable {
    public static let shared = UsageSnapshotStore()

    private let dbURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    public init(dbURL: URL? = nil) {
        if let dbURL {
            self.dbURL = dbURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = appSupport.appendingPathComponent("LLMits", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dbURL = dir.appendingPathComponent("usage.sqlite")
        }
        openIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public func loadAll() -> [UUID: UsageSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return [:] }

        let sql = "SELECT payload FROM snapshots;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var result: [UUID: UsageSnapshot] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(stmt, 0) else { continue }
            let data = Data(bytes: cString, count: Int(sqlite3_column_bytes(stmt, 0)))
            if let snap = try? decoder.decode(UsageSnapshot.self, from: data) {
                result[snap.accountID] = snap
            }
        }
        return result
    }

    public func load(accountID: UUID) -> UsageSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return nil }

        let sql = "SELECT payload FROM snapshots WHERE account_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, accountID.uuidString, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }
        let data = Data(bytes: cString, count: Int(sqlite3_column_bytes(stmt, 0)))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    public func save(_ snapshot: UsageSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return }

        let sql = """
        INSERT INTO snapshots (account_id, provider, fetched_at, payload)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(account_id) DO UPDATE SET
            provider = excluded.provider,
            fetched_at = excluded.fetched_at,
            payload = excluded.payload;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, snapshot.accountID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, snapshot.provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, snapshot.fetchedAt.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            debugLog("[Snapshot] save failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    func delete(accountID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard openIfNeeded() else { return }
        let sql = "DELETE FROM snapshots WHERE account_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, accountID.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    @discardableResult
    private func openIfNeeded() -> Bool {
        if db != nil { return true }
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
            debugLog("[Snapshot] open failed: \(dbURL.path)")
            if let db { sqlite3_close(db) }
            db = nil
            return false
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS snapshots (
            account_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            fetched_at REAL NOT NULL,
            payload TEXT NOT NULL
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            debugLog("[Snapshot] schema failed")
            return false
        }
        return true
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
