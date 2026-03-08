import Foundation
import SwiftUI

struct AccountUsageData: Identifiable {
    let id: UUID
    let account: Account
    var groups: [UsageGroup]
    var isLoading: Bool
    var error: String?
}

@MainActor
class UsageDashboardViewModel: ObservableObject {
    @Published var accountUsages: [AccountUsageData] = []
    @Published var isRefreshing = false
    @Published var lastRefreshed: Date?

    private var refreshTimer: Timer?

    private func service(for provider: Provider, antigravityServers: [AntigravityServerInfo] = []) -> UsageService {
        switch provider {
        case .anthropic: return AnthropicService()
        case .openai: return OpenAIService()
        case .antigravity: return AntigravityService(cachedServers: antigravityServers)
        case .cursor: return CursorService()
        }
    }

    private var lastDiscoveredServers: [AntigravityServerInfo] = []
    private var lastDiscoveryTime: Date?

    func refreshAll(accounts: [Account]) {
        // Guard against concurrent refreshes
        guard !isRefreshing else {
            debugLog("[Dashboard] skipping refresh — already in progress")
            return
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
                    antigravityServers = discoverAntigravityServers()
                    lastDiscoveredServers = antigravityServers
                    lastDiscoveryTime = Date()
                    debugLog("[Dashboard] discovered \(antigravityServers.count) Antigravity servers")
                }
            } else {
                antigravityServers = []
            }

            // Initialize entries for all accounts
            accountUsages = accounts.map { account in
                if let existing = accountUsages.first(where: { $0.account.id == account.id }) {
                    return AccountUsageData(
                        id: account.id,
                        account: account,
                        groups: existing.groups,
                        isLoading: true,
                        error: nil
                    )
                }
                return AccountUsageData(
                    id: account.id,
                    account: account,
                    groups: [],
                    isLoading: true,
                    error: nil
                )
            }

            // Build service + token map on main actor
            var tasks: [(UUID, UsageService, String)] = []
            for account in accounts {
                let svc = service(for: account.provider, antigravityServers: antigravityServers)
                let token = KeychainManager.load(key: account.tokenKeychainKey) ?? "mock"
                debugLog("[Dashboard] queuing \(account.provider.rawValue) token=\(String(token.prefix(10)))")
                tasks.append((account.id, svc, token))
            }

            // Fetch all in parallel
            debugLog("[Dashboard] starting task group with \(tasks.count) tasks")
            await withTaskGroup(of: (UUID, [UsageGroup]?, String?).self) { group in
                for (accountId, svc, token) in tasks {
                    group.addTask { @Sendable in
                        debugLog("[Dashboard] task started for \(accountId)")
                        do {
                            let groups = try await svc.fetchUsage(token: token)
                            debugLog("[Dashboard] task completed for \(accountId) with \(groups.count) groups")
                            return (accountId, groups, nil)
                        } catch {
                            debugLog("[Dashboard] task FAILED for \(accountId): \(error)")
                            return (accountId, nil, error.localizedDescription)
                        }
                    }
                }

                for await (accountId, groups, error) in group {
                    debugLog("[Dashboard] received result for \(accountId)")
                    if let idx = self.accountUsages.firstIndex(where: { $0.id == accountId }) {
                        self.accountUsages[idx].groups = groups ?? []
                        self.accountUsages[idx].isLoading = false
                        self.accountUsages[idx].error = error
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
        }
    }

    func startAutoRefresh(accounts: [Account]) {
        // Only refresh if data is stale (>2 min since last refresh)
        let isStale = lastRefreshed == nil || Date().timeIntervalSince(lastRefreshed!) > 120
        if isStale {
            refreshAll(accounts: accounts)
        }

        // Set up timer only if not already running (10 min interval)
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll(accounts: accounts)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    var usagesByProvider: [(provider: Provider, usages: [AccountUsageData])] {
        let grouped = Dictionary(grouping: accountUsages, by: { $0.account.provider })
        return Provider.allCases.compactMap { provider in
            guard let usages = grouped[provider], !usages.isEmpty else { return nil }
            return (provider: provider, usages: usages)
        }
    }
}
