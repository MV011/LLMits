import SwiftUI

struct RosterView: View {
    @EnvironmentObject var dashboardVM: UsageDashboardViewModel

    private let rosterProviders: [Provider] = [.anthropic, .openai]

    var body: some View {
        let grouped = Dictionary(grouping: dashboardVM.rosterSnapshots, by: \.provider)
        if dashboardVM.rosterSnapshots.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(rosterProviders) { provider in
                        let snaps = sorted(grouped[provider] ?? [])
                        if !snaps.isEmpty {
                            providerBlock(provider, snaps: snaps)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.2")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No cached accounts yet")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Use Claude or Codex, then switch.\nLast percentages stay here.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func providerBlock(_ provider: Provider, snaps: [UsageSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                provider.icon
                    .frame(width: 12, height: 12)
                Text(provider.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .padding(.top, 2)

            ForEach(snaps) { snap in
                identityRow(snap, provider: provider)
            }
        }
    }

    private func identityRow(_ snap: UsageSnapshot, provider: Provider) -> some View {
        let live = isLive(snap)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(snap.identity ?? snap.accountID.uuidString)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if live {
                    Text("live")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                }

                Spacer()

                if !live {
                    Button {
                        dashboardVM.deleteRosterIdentity(snap)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.quaternary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove cached account")
                }
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let pills = RosterPills.pills(for: provider, groups: snap.groups, at: context.date)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                            pillView(pill, at: context.date)
                        }
                    }
                    if pills.contains(where: { $0.kind == .fiveHourExhausted }) {
                        Text("exhausted \(snap.fetchedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
            }

            Text(live
                 ? "updated \(snap.fetchedAt.formatted(.relative(presentation: .named)))"
                 : "cached \(snap.fetchedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func pillView(_ pill: RosterPill, at date: Date) -> some View {
        if let limit = pill.limit {
            switch pill.kind {
            case .remainingPercent:
                let remaining = Int(limit.percentRemaining(at: date) * 100)
                LimitCapsule(
                    label: pill.label,
                    text: "\(remaining)%",
                    color: limit.limitColor(at: date)
                )
            case .resetCountdown:
                LimitCapsule(
                    label: nil,
                    text: compactCountdown(limit, at: date) ?? "reset",
                    color: Color.primary.opacity(0.55)
                )
            case .fiveHourExhausted:
                LimitCapsule(
                    label: "5h",
                    text: compactCountdown(limit, at: date) ?? "maxed",
                    color: .red
                )
            }
        }
    }

    private func compactCountdown(_ limit: UsageLimit, at date: Date) -> String? {
        guard let resetAt = limit.resetAt else { return nil }
        return TimeFormatter.formatCompactRemaining(resetAt.timeIntervalSince(date))
    }

    private func isLive(_ snap: UsageSnapshot) -> Bool {
        guard let identity = snap.identity else { return false }
        return dashboardVM.accountUsages.contains { usage in
            usage.account.provider == snap.provider
                && usage.identity?.localizedCaseInsensitiveCompare(identity) == .orderedSame
        }
    }

    private func sorted(_ snaps: [UsageSnapshot]) -> [UsageSnapshot] {
        snaps.sorted { a, b in
            let liveA = isLive(a)
            let liveB = isLive(b)
            if liveA != liveB { return liveA && !liveB }
            return a.fetchedAt > b.fetchedAt
        }
    }
}

private struct LimitCapsule: View {
    var label: String?
    var text: String
    var color: Color

    var body: some View {
        HStack(spacing: 2) {
            if let label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(color.opacity(0.7))
            }
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}
