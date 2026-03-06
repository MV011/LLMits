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
        var store = loadStore()
        store[key] = value
        saveStore(store)
    }

    static func load(key: String) -> String? {
        loadStore()[key]
    }

    static func delete(key: String) {
        var store = loadStore()
        store.removeValue(forKey: key)
        saveStore(store)
    }

    // MARK: - File I/O

    private static func loadStore() -> [String: String] {
        guard let data = try? Data(contentsOf: storageFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func saveStore(_ store: [String: String]) {
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storageFile, options: .atomic)
            // Set owner-only permissions (0600)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: storageFile.path
            )
        }
    }
}
