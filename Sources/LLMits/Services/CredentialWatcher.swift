import Foundation

/// Watches the CLI credential locations and fires a debounced callback when the
/// credentials actually change — e.g. the user re-logs into Grok or switches
/// Claude accounts while the app is running — so the dashboard refreshes
/// immediately instead of waiting for the next timer tick.
///
/// Two layers of noise suppression, because these directories see plenty of
/// unrelated writes (Claude Code session files in ~/.claude, Cursor state in
/// globalStorage):
/// 1. Filesystem events are debounced and throttled.
/// 2. On each debounced event a credential *fingerprint* (file mtimes, account
///    email, Cursor token hash) is compared — the callback only fires when the
///    fingerprint differs, so directory churn never causes spurious refreshes.
///
/// Credential files are atomically replaced on login (write-to-temp + rename),
/// which breaks per-file vnode watching, so containing directories are watched.
final class CredentialWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?
    private var lastFingerprint: String?
    private var lastFired: Date?
    private let queue = DispatchQueue(label: "llmits.credential-watcher", qos: .utility)
    private let onChange: () -> Void

    private let debounceInterval: TimeInterval = 3
    /// Minimum spacing between callbacks, regardless of event volume.
    private let minFireInterval: TimeInterval = 30

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    private static var watchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude"),                // Claude Code credentials fallback
            home.appendingPathComponent(".grok"),                  // Grok CLI auth.json
            home.appendingPathComponent(".codex"),                 // Codex CLI auth.json
            home.appendingPathComponent(".gemini"),                // Gemini/Antigravity oauth_creds.json
            home.appendingPathComponent(".kimi-code/credentials"), // Kimi Code kimi-code.json
            home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage"  // Cursor state.vscdb
            ),
        ]
    }

    func start() {
        guard sources.isEmpty else { return }

        queue.async { [weak self] in
            self?.lastFingerprint = Self.credentialFingerprint()
        }

        for dir in Self.watchDirectories {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleCheck()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
            debugLog("[CredentialWatcher] watching \(dir.path)")
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    private func scheduleCheck() {
        debounceWorkItem?.cancel()

        var delay = debounceInterval
        if let last = lastFired {
            let sinceLast = Date().timeIntervalSince(last)
            if sinceLast < minFireInterval {
                delay = max(delay, minFireInterval - sinceLast)
            }
        }

        let work = DispatchWorkItem { [weak self] in
            self?.checkForCredentialChange()
        }
        debounceWorkItem = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkForCredentialChange() {
        let fingerprint = Self.credentialFingerprint()
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        lastFired = Date()
        debugLog("[CredentialWatcher] credential change detected, notifying")
        onChange()
    }

    // MARK: - Fingerprint

    /// Compact per-process snapshot of the credential state across providers.
    /// Only compared for equality — never persisted, never logged.
    private static func credentialFingerprint() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var parts: [String] = []

        // File-based credentials: mtime + size is enough — a login/refresh
        // always rewrites the file.
        let credentialFiles = [
            ".grok/auth.json",
            ".codex/auth.json",
            ".gemini/oauth_creds.json",
            ".gemini/google_accounts.json",
            ".claude/.credentials.json",
            ".claude/credentials.json",
            ".kimi-code/credentials/kimi-code.json",
        ]
        for rel in credentialFiles {
            let path = home.appendingPathComponent(rel).path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
                parts.append("\(rel):\(mtime):\(size)")
            }
        }

        // Claude Code on macOS keeps its OAuth credential in the Keychain (no
        // file to stat) — the visible account-switch signal is oauthAccount in
        // ~/.claude.json. That file churns for other reasons, so extract just
        // the account identity rather than using its mtime.
        let claudeConfig = home.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: claudeConfig),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let account = json["oauthAccount"] as? [String: Any] {
            let identity = (account["emailAddress"] as? String)
                ?? (account["accountUuid"] as? String)
                ?? ""
            parts.append("claude:\(identity)")
        }

        // Cursor's state.vscdb changes constantly while the IDE runs — only
        // the auth tokens inside it matter. hashValue is stable within a
        // process run, which is all an equality check needs.
        if let (userId, jwt) = CursorService.readAuthTokensSync() {
            parts.append("cursor:\(userId):\(jwt.hashValue)")
        }

        return parts.joined(separator: "|")
    }
}
