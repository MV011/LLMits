import Foundation

/// Process-level cache for resolved OAuth tokens.
/// Avoids repeated Keychain access prompts from macOS.
final class TokenCache {
    static let shared = TokenCache()

    private var cache: [String: String] = [:]
    private var objectCache: [String: Any] = [:]
    private let lock = NSLock()

    private init() {}

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func set(_ key: String, value: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = value
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: key)
        objectCache.removeValue(forKey: key)
    }

    func getObject<T>(_ key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return objectCache[key] as? T
    }

    func setObject(_ key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        objectCache[key] = value
    }
}
