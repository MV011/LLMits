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

    func refreshAll(accounts: [Account]) {
        Task {
            isRefreshing = true
            debugLog("[Dashboard] refreshAll with \(accounts.count) accounts")

            // Pre-discover Antigravity servers BEFORE entering the task group.
            // Process.waitUntilExit() deadlocks inside withTaskGroup child tasks
            // because it conflicts with Swift's cooperative thread pool executor.
            let antigravityServers: [AntigravityServerInfo]
            if accounts.contains(where: { $0.provider == .antigravity }) {
                antigravityServers = discoverAntigravityServers()
                debugLog("[Dashboard] pre-discovered \(antigravityServers.count) Antigravity servers")
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
            isRefreshing = false
            lastRefreshed = Date()
        }
    }

    func startAutoRefresh(accounts: [Account]) {
        refreshTimer?.invalidate()
        refreshAll(accounts: accounts)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
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
