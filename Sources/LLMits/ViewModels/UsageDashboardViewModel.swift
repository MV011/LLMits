import AppKit
import Foundation
import SwiftUI

struct AccountUsageData: Identifiable {
    let id: UUID
    let account: Account
    var groups: [UsageGroup]
    var isLoading: Bool
    var error: String?
    /// Identity (email/user id) the live credential belongs to — may differ
    /// from the account's stored display name after a CLI account switch.
    var identity: String?
}

@MainActor
class UsageDashboardViewModel: ObservableObject {
    @Published var accountUsages: [AccountUsageData] = []
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?

    private var refreshTimer: Timer?
    private var credentialWatcher: CredentialWatcher?
    private var wakeObserver: NSObjectProtocol?
    private var errorRetryTask: Task<Void, Never>?
    private var errorRetryCount = 0

    private func service(for provider: Provider, antigravityServers: [AntigravityServerInfo] = []) -> UsageService {
        switch provider {
        case .anthropic: return AnthropicService()
        case .openai: return OpenAIService()
        case .antigravity: return AntigravityService(cachedServers: antigravityServers)
        case .cursor: return CursorService()
        case .grok: return GrokService()
        case .kimi: return KimiService()
        }
    }

    private var lastDiscoveredServers: [AntigravityServerInfo] = []
    private var lastDiscoveryTime: Date?
    private var latestAccounts: [Account] = []

    func refreshAll(accounts: [Account], force: Bool = false) {
        // Guard against concurrent refreshes
        guard !isRefreshing else {
            debugLog("[Dashboard] skipping refresh — already in progress")
            return
        }

        latestAccounts = accounts

        // Stale-while-revalidate: keep existing data visible unless this is a forced refresh
        // or we have no cached rows for an account yet.
        accountUsages = accounts.map { account in
            if let existing = accountUsages.first(where: { $0.account.id == account.id }) {
                return AccountUsageData(
                    id: account.id,
                    account: account,
                    groups: existing.groups,
                    isLoading: force || existing.groups.isEmpty,
                    error: nil,
                    identity: existing.identity
                )
            }
            return AccountUsageData(
                id: account.id,
                account: account,
                groups: [],
                isLoading: true,
                error: nil,
                identity: nil
            )
        }

        Task {
            isRefreshing = true
            defer { isRefreshing = false }
            debugLog("[Dashboard] refreshAll with \(accounts.count) accounts")

            // Re-use cached Antigravity servers if discovered within last 60s
            let antigravityServers: [AntigravityServerInfo]
            if accounts.contains(where: { $0.provider == .antigravity }) {
                if let cached = lastDiscoveryTime,
                   Date().timeIntervalSince(cached) < 60,
                   !lastDiscoveredServers.isEmpty {
                    antigravityServers = lastDiscoveredServers
                    debugLog("[Dashboard] reusing \(antigravityServers.count) cached Antigravity servers")
                } else {
                    // Offload the Process + wait so we don't block the current task's thread
                    // (the function itself documents it must be outside task groups due to wait).
                    antigravityServers = await Task.detached {
                        discoverAntigravityServers()
                    }.value
                    lastDiscoveredServers = antigravityServers
                    lastDiscoveryTime = Date()
                    debugLog("[Dashboard] discovered \(antigravityServers.count) Antigravity servers")
                }
            } else {
                antigravityServers = []
            }

            // Build service + token map (offload cheap file reads for cleanliness)
            let accountsForTasks = accounts
            let tokens = await withTaskGroup(of: (Int, String).self) { group -> [Int: String] in
                var map: [Int: String] = [:]
                for (i, account) in accountsForTasks.enumerated() {
                    group.addTask {
                        let t = KeychainManager.load(key: account.tokenKeychainKey) ?? "mock"
                        return (i, t)
                    }
                }
                for await (i, t) in group {
                    map[i] = t
                }
                return map
            }

            var tasks: [(UUID, UsageService, String)] = []
            for (i, account) in accountsForTasks.enumerated() {
                let svc = service(for: account.provider, antigravityServers: antigravityServers)
                let token = tokens[i] ?? "mock"
                debugLog("[Dashboard] queuing \(account.provider.rawValue) token=\(String(token.prefix(10)))")
                tasks.append((account.id, svc, token))
            }

            // Fetch all in parallel
            debugLog("[Dashboard] starting task group with \(tasks.count) tasks")
            await withTaskGroup(of: (UUID, [UsageGroup]?, String?, String?).self) { group in
                for (accountId, svc, token) in tasks {
                    group.addTask { @Sendable in
                        debugLog("[Dashboard] task started for \(accountId)")
                        let identity = await svc.currentIdentity()
                        do {
                            let groups = try await svc.fetchUsage(token: token)
                            debugLog("[Dashboard] task completed for \(accountId) with \(groups.count) groups")
                            return (accountId, groups, nil, identity)
                        } catch {
                            debugLog("[Dashboard] task FAILED for \(accountId): \(error)")
                            return (accountId, nil, error.localizedDescription, identity)
                        }
                    }
                }

                for await (accountId, groups, error, identity) in group {
                    debugLog("[Dashboard] received result for \(accountId)")
                    if let idx = self.accountUsages.firstIndex(where: { $0.id == accountId }) {
                        self.accountUsages[idx].groups = groups ?? []
                        self.accountUsages[idx].isLoading = false
                        self.accountUsages[idx].error = error
                        self.accountUsages[idx].identity = identity
                    }
                }
            }

            debugLog("[Dashboard] all tasks completed")
            debugLog("[Dashboard] accountUsages count=\(self.accountUsages.count), total groups=\(self.accountUsages.flatMap(\.groups).count)")
            debugLog("[Dashboard] usagesByProvider count=\(self.usagesByProvider.count)")
            for item in self.usagesByProvider {
                debugLog("[Dashboard]   provider=\(item.provider.rawValue) usages=\(item.usages.count) groups=\(item.usages.flatMap(\.groups).count) loading=\(item.usages.map(\.isLoading))")
            }
            lastRefreshed = Date()
            scheduleErrorRetryIfNeeded()
        }
    }

    /// After a refresh that left accounts in an error state, retry sooner than the
    /// 10-minute timer — with exponential backoff (60s → 600s cap) so a persistent
    /// failure never hammers anything. Resets once a refresh comes back clean.
    private func scheduleErrorRetryIfNeeded() {
        errorRetryTask?.cancel()
        guard accountUsages.contains(where: { $0.error != nil }) else {
            errorRetryCount = 0
            return
        }

        let delay = min(60.0 * pow(2.0, Double(errorRetryCount)), 600.0)
        errorRetryCount += 1
        debugLog("[Dashboard] \(accountUsages.filter { $0.error != nil }.count) account(s) in error, retrying in \(Int(delay))s")

        errorRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshAll(accounts: self.latestAccounts)
        }
    }

    func refreshOnAppear(accounts: [Account]) {
        latestAccounts = accounts
        let isStale = lastRefreshed.map { Date().timeIntervalSince($0) > 60 } ?? true
        if isStale {
            refreshAll(accounts: accounts)
        }
        startPeriodicRefresh()
        startCredentialWatcher()
        startWakeObserver()
    }

    private func startPeriodicRefresh() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAll(accounts: self.latestAccounts)
            }
        }
    }

    /// Refresh as soon as a CLI credential changes on disk (login, logout,
    /// account switch, token rotation) instead of waiting for the timer.
    /// While the popover is closed (auto-refresh stopped) nothing is fetched —
    /// the data is just marked stale so reopening refreshes immediately.
    private func startCredentialWatcher() {
        guard credentialWatcher == nil else { return }
        let watcher = CredentialWatcher { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A CLI credential changed (login, account switch, token
                // rotation) — drop all cached tokens first, otherwise a
                // still-valid cached token keeps serving the OLD account's
                // data while the identity line already shows the new one.
                await TokenResolver.shared.invalidateCache()
                TokenCache.shared.invalidateAllProviders()
                if self.refreshTimer != nil {
                    self.refreshAll(accounts: self.latestAccounts)
                } else {
                    self.lastRefreshed = nil
                }
            }
        }
        watcher.start()
        credentialWatcher = watcher
    }

    /// Refresh stale data when the Mac wakes from sleep — the 10-minute timer
    /// doesn't fire while asleep, so without this the popover shows old numbers
    /// (and possibly expired-credential errors) right when the user comes back.
    private func startWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.refreshTimer != nil else { return }
                let isStale = self.lastRefreshed.map { Date().timeIntervalSince($0) > 60 } ?? true
                if isStale {
                    debugLog("[Dashboard] system woke, refreshing stale data")
                    self.refreshAll(accounts: self.latestAccounts)
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        errorRetryTask?.cancel()
        errorRetryTask = nil
        // The credential watcher and wake observer intentionally stay alive —
        // they make no network requests while auto-refresh is stopped, they only
        // invalidate `lastRefreshed` so the next popover open refreshes at once.
    }

    var usagesByProvider: [(provider: Provider, usages: [AccountUsageData])] {
        let grouped = Dictionary(grouping: accountUsages, by: { $0.account.provider })
        return Provider.allCases.compactMap { provider in
            guard let usages = grouped[provider], !usages.isEmpty else { return nil }
            return (provider: provider, usages: usages)
        }
    }
}
