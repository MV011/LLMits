import Foundation
import SwiftUI
import Security

@MainActor
class AccountsViewModel: ObservableObject {
    @Published var accounts: [Account] = [] {
        didSet { saveAccounts() }
    }

    private let accountsKey = "llmits.accounts"
    private let hasRunAutoDiscoveryKey = "llmits.hasRunAutoDiscovery"

    init() {
        loadAccounts()
    }

    /// Call this after app launch to auto-discover credentials.
    /// Must be called explicitly (not from init) to avoid blocking the main thread.
    func runAutoDiscoveryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: hasRunAutoDiscoveryKey) else { return }
        UserDefaults.standard.set(true, forKey: hasRunAutoDiscoveryKey)

        Task.detached { [weak self] in
            let hasClaude = Self.hasClaudeCodeCredentials()
            let hasCodex = Self.hasCodexCredentials()
            let hasAntigravity = Self.isAntigravityRunning()
            let hasCursor = CursorService.readCursorJWT() != nil

            await MainActor.run {
                guard let self = self else { return }
                if hasClaude && self.accountsFor(provider: .anthropic).isEmpty {
                    self.addAccount(provider: .anthropic, displayName: "Claude Code", token: "mock-token")
                }
                if hasCodex && self.accountsFor(provider: .openai).isEmpty {
                    self.addAccount(provider: .openai, displayName: "Codex CLI", token: "mock-token")
                }
                if hasAntigravity && self.accountsFor(provider: .antigravity).isEmpty {
                    self.addAccount(provider: .antigravity, displayName: "Antigravity", token: "mock-token")
                }
                if hasCursor && self.accountsFor(provider: .cursor).isEmpty {
                    self.addAccount(provider: .cursor, displayName: "Cursor", token: "mock-token")
                }
            }
        }
    }

    func addAccount(provider: Provider, displayName: String, token: String) {
        let account = Account(provider: provider, displayName: displayName)
        try? KeychainManager.save(key: account.tokenKeychainKey, value: token)
        accounts.append(account)
    }

    func removeAccount(_ account: Account) {
        KeychainManager.delete(key: account.tokenKeychainKey)
        accounts.removeAll(where: { $0.id == account.id })
    }

    func updateToken(for account: Account, newToken: String) {
        try? KeychainManager.save(key: account.tokenKeychainKey, value: newToken)
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

    nonisolated private static func isAntigravityRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "command="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return false }

        // Read pipe BEFORE waitUntilExit to avoid pipe buffer deadlock
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        return output.contains("language_server_macos") && output.contains("antigravity")
    }

    // MARK: - Persistence

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let saved = try? JSONDecoder().decode([Account].self, from: data) else {
            return
        }
        accounts = saved
    }
}
