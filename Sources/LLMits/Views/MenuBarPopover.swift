import SwiftUI
import ServiceManagement

enum PopoverPage {
    case dashboard
    case settings
    case addAccount
}

struct MenuBarPopover: View {
    @EnvironmentObject var dashboardVM: UsageDashboardViewModel
    @EnvironmentObject var accountsVM: AccountsViewModel
    @State private var currentPage: PopoverPage = .dashboard

    var body: some View {
        VStack(spacing: 0) {
            switch currentPage {
            case .dashboard:
                dashboardView
            case .settings:
                settingsView
            case .addAccount:
                addAccountView
            }
        }
        .frame(width: 360, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            accountsVM.runAutoDiscoveryIfNeeded()
            dashboardVM.startAutoRefresh(accounts: accountsVM.accounts)
        }
        .onDisappear {
            dashboardVM.stopAutoRefresh()
        }
    }

    // MARK: - Dashboard

    private var dashboardView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LLMits")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text("AI Usage Tracker")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dashboardVM.refreshAll(accounts: accountsVM.accounts)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(dashboardVM.isRefreshing ? 360 : 0))
                        .animation(
                            dashboardVM.isRefreshing
                                ? .linear(duration: 1.0).repeatForever(autoreverses: false)
                                : .default,
                            value: dashboardVM.isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .help("Refresh all")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // Thin accent line
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.blue.opacity(0.6), .purple.opacity(0.4), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1.5)
                .padding(.horizontal, 12)

            // Content
            if accountsVM.accounts.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(dashboardVM.usagesByProvider, id: \.provider) { item in
                            ProviderSection(
                                provider: item.provider,
                                usages: item.usages
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }

            Spacer(minLength: 0)

            // Footer
            Divider()
                .padding(.horizontal, 8)

            HStack(spacing: 12) {
                if let last = dashboardVM.lastRefreshed {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.quaternary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = .settings
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit LLMits")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.08))
                    .frame(width: 72, height: 72)
                Image(systemName: "gauge.with.dots.needle.0percent")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.blue.opacity(0.5))
            }

            VStack(spacing: 4) {
                Text("No accounts configured")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Add your AI provider accounts\nto start tracking usage.")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentPage = .addAccount
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12))
                    Text("Add Account")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding()
    }

    // MARK: - Settings View (inline)

    private var settingsView: some View {
        VStack(spacing: 0) {
            // Header with back button
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = .dashboard
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Back")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Accounts")
                    .font(.system(size: 14, weight: .bold, design: .rounded))

                Spacer()

                // Balance the back button width
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = .addAccount
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Add account")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.blue.opacity(0.15))
                .frame(height: 1)
                .padding(.horizontal, 12)

            if accountsVM.accounts.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No accounts yet")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(Provider.allCases) { provider in
                            let providerAccounts = accountsVM.accountsFor(provider: provider)
                            if !providerAccounts.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        provider.icon
                                            .frame(width: 12, height: 12)
                                        Text(provider.displayName)
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 4)
                                    .padding(.top, 6)

                                    ForEach(providerAccounts) { account in
                                        accountRow(account)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 0)

            // Launch at Login toggle
            Divider()
                .padding(.horizontal, 12)

            HStack {
                Image(systemName: "sunrise.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Launch at Login")
                    .font(.system(size: 12, weight: .medium, design: .rounded))

                Spacer()

                Toggle("", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            debugLog("[Settings] launch at login error: \(error)")
                        }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func accountRow(_ account: Account) -> some View {
        HStack(spacing: 10) {
            let hasToken = KeychainManager.load(key: account.tokenKeychainKey) != nil

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Text(hasToken ? "Token configured" : "No token")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(hasToken ? .green : .orange)
            }

            Spacer()

            Button {
                accountsVM.removeAccount(account)
                dashboardVM.refreshAll(accounts: accountsVM.accounts)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove account")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Add Account View (inline)

    private var addAccountView: some View {
        AddAccountView(
            onDone: {
                dashboardVM.refreshAll(accounts: accountsVM.accounts)
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentPage = .dashboard
                }
            },
            onCancel: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    currentPage = accountsVM.accounts.isEmpty ? .dashboard : .settings
                }
            }
        )
    }
}
