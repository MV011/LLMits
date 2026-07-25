import Foundation

/// File-based token storage to avoid macOS Keychain prompts on debug builds.
/// Stores tokens in ~/Library/Application Support/LLMits/tokens.json.
/// This is used for LLMits's own account tokens only — Claude Code's
/// Keychain entry is read separately (once, cached in memory).
struct KeychainManager {
    private static let storageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LLMits")
    }()

    private static let storageFile: URL = {
        storageDir.appendingPathComponent("tokens.json")
    }()

    static func save(key: String, value: String) throws {
        var store = try loadStore()
        store[key] = value
        try saveStore(store)
    }

    static func load(key: String) -> String? {
        (try? loadStore())?[key]
    }

    static func delete(key: String) {
        // Refuse to touch the store if it can't be read — see loadStore.
        guard var store = try? loadStore() else { return }
        store.removeValue(forKey: key)
        try? saveStore(store)
    }

    // MARK: - File I/O

    /// Throws on anything but a missing file. A corrupt store must NOT be
    /// treated as empty: the next save would silently wipe all other tokens.
    private static func loadStore() throws -> [String: String] {
        do {
            let data = try Data(contentsOf: storageFile)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return [:]  // No store yet — legitimately empty
            }
            debugLog("[Keychain] loadStore failed, refusing to treat store as empty: \(error)")
            throw error
        }
    }

    private static func saveStore(_ store: [String: String]) throws {
        do {
            try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
            // Create the file 0600 up front so it never exists world-readable —
            // the atomic write below would create it 0644 before any chmod.
            if !FileManager.default.fileExists(atPath: storageFile.path) {
                FileManager.default.createFile(
                    atPath: storageFile.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let data = try JSONEncoder().encode(store)
            try data.write(to: storageFile, options: .atomic)
            // Atomic write re-creates the file — re-assert owner-only permissions (0600)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: storageFile.path
            )
        } catch {
            debugLog("[Keychain] saveStore failed: \(error)")
            throw error
        }
    }
}
