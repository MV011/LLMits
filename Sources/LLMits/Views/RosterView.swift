import SwiftUI

struct RosterView: View {
    @EnvironmentObject var dashboardVM: UsageDashboardViewModel
    private let providers: [Provider] = [.anthropic, .openai]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if dashboardVM.rosterSnapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(providers) { provider in
                            let snapshots = RosterOrdering.sorted(
                                dashboardVM.rosterSnapshots.filter { $0.provider == provider }, at: context.date
                            )
                            if !snapshots.isEmpty {
                                providerSection(provider, snapshots: snapshots, at: context.date)
                            }
                        }
                        Text("≈ Estimated · warmer = reset sooner")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    .padding(14)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No saved accounts")
                .font(.system(size: 15, weight: .semibold))
            Text("Use Claude or Codex to save usage here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func providerSection(_ provider: Provider, snapshots: [UsageSnapshot], at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                provider.icon.frame(width: 14, height: 14)
                Text(provider == .anthropic ? "Claude" : "Codex")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(snapshots.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Soonest first", systemImage: "arrow.up")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(provider == .anthropic
                          ? "Available accounts first, ordered by the next weekly reset."
                          : "Available accounts first, ordered by the earliest recorded reset.")
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Limit").frame(width: 44, alignment: .leading)
                    Text("Left").frame(width: 70, alignment: .leading)
                    Spacer(minLength: 0)
                    Text("Reset")
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
                ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    if index > 0 { Divider().padding(.horizontal, 12) }
                    RosterAccountRow(snapshot: snapshot, date: date, isCurrent: isCurrent(snapshot)) {
                        dashboardVM.deleteRosterIdentity(snapshot)
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func isCurrent(_ snapshot: UsageSnapshot) -> Bool {
        guard let identity = snapshot.identity else { return false }
        return dashboardVM.accountUsages.contains { usage in
            usage.account.provider == snapshot.provider
                && usage.identity?.localizedCaseInsensitiveCompare(identity) == .orderedSame
        }
    }
}

private struct RosterAccountRow: View {
    let snapshot: UsageSnapshot
    let date: Date
    let isCurrent: Bool
    let onRemove: () -> Void
    @State private var showsDetails = false
    @Environment(\.colorScheme) private var colorScheme

    private var pills: [RosterPill] {
        RosterPills.pills(for: snapshot.provider, groups: snapshot.groups, at: date, fetchedAt: snapshot.fetchedAt)
    }

    private var urgency: RosterUrgency {
        RosterUrgency.level(for: snapshot, at: date, isCurrent: isCurrent)
    }

    private var background: Color {
        let dark = colorScheme == .dark
        switch urgency {
        case .none: return .clear
        case .ready: return .teal.opacity(dark ? 0.13 : 0.06)
        case .approaching: return .yellow.opacity(dark ? 0.15 : 0.10)
        case .soon: return .orange.opacity(dark ? 0.19 : 0.12)
        case .urgent: return .red.opacity(dark ? 0.22 : 0.13)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(snapshot.identity ?? "Saved account")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(snapshot.identity ?? snapshot.accountID.uuidString)
                Spacer(minLength: 0)
                Menu {
                    Button("Account details", systemImage: "info.circle") { showsDetails = true }
                    if !isCurrent {
                        Button("Remove cached account", systemImage: "trash", role: .destructive, action: onRemove)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Options for \(snapshot.identity ?? "saved account")")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusable()
                .accessibilityLabel("Options for \(snapshot.identity ?? "saved account")")
                .help("Account details and options")
                .popover(isPresented: $showsDetails) {
                    details.padding(16).frame(width: 300)
                }
            }

            if pills.isEmpty {
                Text("Usage unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                        RosterLimitRow(pill: pill, date: date)
                    }
                }
            }

            HStack(spacing: 5) {
                Text("Cached \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                    .help(snapshot.fetchedAt.formatted(date: .complete, time: .shortened))
                Spacer()
                if isCurrent {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("Current")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityValue(urgency.accessibilityDescription)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.identity ?? "Saved account")
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
            Text("Cached \(snapshot.fetchedAt.formatted(date: .complete, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                VStack(alignment: .leading, spacing: 3) {
                    Text(pill.label == "Wk" ? "Weekly" : (pill.label == "5h" ? "5 hour" : pill.label))
                        .font(.system(size: 12, weight: .medium))
                    Text(pill.resetHelp(at: date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RosterLimitRow: View {
    let pill: RosterPill
    let date: Date

    private var title: String {
        switch pill.label {
        case "Wk": return "Weekly"
        case "5h": return "5 hour"
        default: return pill.label
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            if let limit = pill.limit {
                Text("\(pill.kind == .resetPassed ? "≈" : "")\(limit.remainingPercentage(at: date))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(limit.remainingPercentage(at: date) <= 10 ? Color.red : Color.primary)
                    .frame(width: 70, alignment: .leading)
                    .accessibilityLabel("\(pill.kind == .resetPassed ? "Estimated " : "")\(limit.remainingPercentage(at: date)) percent remaining")
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let next = pill.nextReset(at: date) {
                    Text(next.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                        .font(.system(size: 11, weight: .medium))
                    Text(TimeFormatter.formatCompactRemaining(next.timeIntervalSince(date)) ?? "<1m")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let reset = pill.limit?.resetAt, reset <= date {
                    Text("Ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                    Text(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reset unknown")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .help(pill.resetHelp(at: date))
        .accessibilityElement(children: .combine)
        .accessibilityHint(pill.resetDescription(at: date))
    }
}
