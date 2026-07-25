import Foundation
import SwiftUI
import Security

@MainActor
class AccountsViewModel: ObservableObject {
    @Published var accounts: [Account] = [] {
        didSet { saveAccounts() }
    }

    private let accountsKey = "llmits.accounts"
    // Bump the version suffix when new auto-discoverable providers are added
    private let hasRunAutoDiscoveryKey = "llmits.hasRunAutoDiscovery.v5"
    // Providers the user explicitly deleted — auto-discovery must not resurrect them
    private let tombstonedProvidersKey = "llmits.tombstonedProviders"

    private var tombstonedProviders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: tombstonedProvidersKey) ?? [])
    }

    init() {
        loadAccounts()
    }

    /// Call this after app launch to auto-discover credentials.
    /// Must be called explicitly (not from init) to avoid blocking the main thread.
    func runAutoDiscoveryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: hasRunAutoDiscoveryKey) else { return }

        Task.detached { [weak self] in
            let hasClaude = Self.hasClaudeCodeCredentials()
            let hasCodex = Self.hasCodexCredentials()
            let hasAntigravity = Self.isAntigravityAvailable()
            let hasCursor = CursorService.readCursorJWT() != nil
            let hasGrok = Self.hasGrokCredentials()
            let hasKimi = Self.hasKimiCredentials()

            // Capture weak self before entering MainActor context
            guard let vm = self else { return }
            await MainActor.run {
                // Mark as run only now that the checks completed — setting the
                // flag up front means a quit in between skips discovery forever.
                UserDefaults.standard.set(true, forKey: vm.hasRunAutoDiscoveryKey)
                let tombstoned = vm.tombstonedProviders
                if hasClaude && !tombstoned.contains(Provider.anthropic.rawValue) && vm.accountsFor(provider: .anthropic).isEmpty {
                    vm.addAccount(provider: .anthropic, displayName: "Claude Code", token: "mock-token")
                }
                if hasCodex && !tombstoned.contains(Provider.openai.rawValue) && vm.accountsFor(provider: .openai).isEmpty {
                    vm.addAccount(provider: .openai, displayName: "Codex CLI", token: "mock-token")
                }
                if hasAntigravity && !tombstoned.contains(Provider.antigravity.rawValue) && vm.accountsFor(provider: .antigravity).isEmpty {
                    vm.addAccount(provider: .antigravity, displayName: "Antigravity", token: "mock-token")
                }
                if hasCursor && !tombstoned.contains(Provider.cursor.rawValue) && vm.accountsFor(provider: .cursor).isEmpty {
                    vm.addAccount(provider: .cursor, displayName: "Cursor", token: "mock-token")
                }
                if hasGrok && !tombstoned.contains(Provider.grok.rawValue) && vm.accountsFor(provider: .grok).isEmpty {
                    vm.addAccount(provider: .grok, displayName: "Grok Build", token: "mock-token")
                }
                if hasKimi && !tombstoned.contains(Provider.kimi.rawValue) && vm.accountsFor(provider: .kimi).isEmpty {
                    vm.addAccount(provider: .kimi, displayName: "Kimi Code", token: "mock-token")
                }
            }
        }
    }

    func addAccount(provider: Provider, displayName: String, token: String) {
        // Auto-discovered providers read the same on-disk credentials —
        // a second account for the same provider would be a duplicate.
        if provider.isAutoDiscovered && !accountsFor(provider: provider).isEmpty {
            return
        }
        let account = Account(provider: provider, displayName: displayName)
        try? KeychainManager.save(key: account.tokenKeychainKey, value: token)
        accounts.append(account)
    }

    func removeAccount(_ account: Account) {
        KeychainManager.delete(key: account.tokenKeychainKey)
        accounts.removeAll(where: { $0.id == account.id })
        // Tombstone the provider so a later auto-discovery (e.g. after the
        // discovery-version key is bumped) doesn't resurrect the account.
        var tombstoned = tombstonedProviders
        tombstoned.insert(account.provider.rawValue)
        UserDefaults.standard.set(Array(tombstoned), forKey: tombstonedProvidersKey)
    }

    func accountsFor(provider: Provider) -> [Account] {
        accounts.filter { $0.provider == provider }
    }

    // MARK: - Auto-Discovery (static, runs off main)

    nonisolated private static func hasClaudeCodeCredentials() -> Bool {
        // Only check file paths — do NOT touch Keychain here to avoid password prompts.
        // The actual Keychain read happens in AnthropicService.fetchUsage() (once, cached).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".claude/.credentials.json"),
            home.appendingPathComponent(".claude/credentials.json"),
            home.appendingPathComponent(".claude"),  // Claude dir exists = CLI installed
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated private static func hasCodexCredentials() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            if FileManager.default.fileExists(atPath: URL(fileURLWithPath: codexHome)
                .appendingPathComponent("auth.json").path) {
                return true
            }
        }
        return FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".codex/auth.json").path
        )
    }

    nonisolated private static func hasGrokCredentials() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".grok/auth.json").path
        )
    }

    nonisolated private static func hasKimiCredentials() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".kimi-code/credentials/kimi-code.json").path
        )
    }

    /// Detect Antigravity availability: checks for running processes (desktop app or agy CLI)
    /// AND the OAuth credentials file used by both surfaces.
    nonisolated private static func isAntigravityAvailable() -> Bool {
        // Check 1: OAuth creds file exists (works for both CLI and desktop)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hasOAuthCreds = FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".gemini/oauth_creds.json").path
        )
        if hasOAuthCreds { return true }

        // Check 2: Antigravity desktop app or agy CLI is running
        guard let output = ProcessRunner.captureOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        ) else { return false }
        // Match per line — a substring match on the whole output would hit any
        // process whose command line merely contains the letters "agy".
        return output.split(separator: "\n").contains { line in
            let command = line.trimmingCharacters(in: .whitespaces)
            // Detect desktop app language server
            if command.contains("language_server") && command.contains("antigravity") {
                return true
            }
            // Detect agy CLI: the executable's basename must be exactly "agy"
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return (executable as NSString).lastPathComponent == "agy"
        }
    }

    // MARK: - Persistence

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    private func loadAccounts() {
        debugLog("[Accounts] loadAccounts: domain=\(Bundle.main.bundleIdentifier ?? "nil")")
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else {
            debugLog("[Accounts] no data for key '\(accountsKey)'")
            return
        }
        debugLog("[Accounts] found \(data.count) bytes")
        guard let saved = try? JSONDecoder().decode([Account].self, from: data) else {
            debugLog("[Accounts] decode failed")
            return
        }
        debugLog("[Accounts] loaded \(saved.count) accounts")
        accounts = saved
    }
}
