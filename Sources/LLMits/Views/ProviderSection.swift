import SwiftUI

struct ProviderSection: View {
    let provider: Provider
    let usages: [AccountUsageData]
    @State private var isExpanded = false

    private var allLimits: [UsageLimit] {
        usages.flatMap { $0.groups.flatMap(\.limits) }
    }

    /// Priority 1: weekly limit exhausted
    private var isWeeklyExhausted: Bool {
        allLimits.contains { $0.windowType == .weekly && $0.percentUsed(at: Date()) >= 1.0 }
    }

    /// Priority 2: 5-hour window exhausted
    private var isFiveHourExhausted: Bool {
        allLimits.contains { $0.windowType == .fiveHour && $0.percentUsed(at: Date()) >= 1.0 }
    }

    /// For multi-model providers (Antigravity): Gemini Pro AND Cloud both exhausted
    private var isAllPinnedExhausted: Bool {
        guard provider == .antigravity else { return false }
        let pro = allLimits.first { $0.name == "Gemini Pro" }
        let cloud = allLimits.first { $0.name == "Cloud" }
        guard let p = pro, let c = cloud else { return false }
        return p.percentUsed >= 1.0 && c.percentUsed >= 1.0
    }

    /// Combined: should the card be red?
    private var isAtLimit: Bool {
        isWeeklyExhausted || isFiveHourExhausted || isAllPinnedExhausted
    }

    /// Reset detail for the exhausted limit
    private var exhaustedResetLimit: UsageLimit? {
        if isWeeklyExhausted {
            return allLimits.first { $0.windowType == .weekly && $0.percentUsed(at: Date()) >= 1.0 }
        }
        if isFiveHourExhausted {
            return allLimits.first { $0.windowType == .fiveHour && $0.percentUsed(at: Date()) >= 1.0 }
        }
        if isAllPinnedExhausted {
            return allLimits.first { $0.name == "Cloud" && $0.percentUsed(at: Date()) >= 1.0 }
        }
        return nil
    }

    /// The first 5-hour window limit (for collapsed badge)
    private var fiveHourLimit: UsageLimit? {
        allLimits.first { $0.windowType == .fiveHour }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Provider header
            Button {
                withAnimation(.spring(duration: 0.25)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    // Provider icon with colored background
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(provider.brandColor.opacity(0.12))
                            .frame(width: 26, height: 26)
                        provider.icon
                            .frame(width: 14, height: 14)
                    }

                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Spacer()

                    // Summary badge when collapsed
                    if !isExpanded {
                        collapsedBadge
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(usages) { usage in
                        accountContent(usage)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isAtLimit && !isExpanded
                      ? Color.red.opacity(0.08)
                      : Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isAtLimit && !isExpanded
                                      ? Color.red.opacity(0.2)
                                      : Color.primary.opacity(0.04), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var collapsedBadge: some View {
        if isAtLimit, let resetLimit = exhaustedResetLimit {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let text = resetLimit.resetDetail(at: context.date)?
                    .replacingOccurrences(of: "Resets in ", with: "") ?? "reset"
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8))
                    Text(text)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.12)))
            }
        } else if provider == .kimi {
            let weekly = allLimits.first { $0.windowType == .weekly }
            let fiveH = allLimits.first { $0.windowType == .fiveHour }
            HStack(spacing: 4) {
                if let fiveH {
                    miniLimitBadge(label: "5h", limit: fiveH)
                }
                if let weekly {
                    miniLimitBadge(label: "Wk", limit: weekly)
                }
                if weekly == nil && fiveH == nil, let first = allLimits.first {
                    percentBadge(remaining: Int(first.percentRemaining(at: Date()) * 100), color: first.limitColor)
                }
            }
        } else if provider == .antigravity {
            // Show Pro + Flash usage (direct API) or Pro + Cloud (language server)
            let proLimit = allLimits.first { $0.name == "Pro" || $0.name == "Gemini Pro" }
            let flashLimit = allLimits.first { $0.name == "Flash" || $0.name == "Gemini Flash" }
            let cloudLimit = allLimits.first { $0.name == "Cloud" }

            HStack(spacing: 4) {
                if let pro = proLimit {
                    miniLimitBadge(label: "Pro", limit: pro)
                }
                if let flash = flashLimit {
                    miniLimitBadge(label: "Flash", limit: flash)
                }
                if let cloud = cloudLimit, flashLimit == nil {
                    miniLimitBadge(label: "Cloud", limit: cloud)
                }
                if proLimit == nil && flashLimit == nil && cloudLimit == nil, let first = allLimits.first {
                    percentBadge(remaining: Int(first.percentRemaining * 100), color: first.limitColor)
                }
            }
        } else if provider == .cursor {
            let auto = allLimits.first { $0.name == "Auto + Composer" }
            let api = allLimits.first { $0.name == "API" }
            HStack(spacing: 4) {
                if let auto {
                    cursorUsedBadge(label: "Auto", limit: auto)
                }
                if let api {
                    cursorUsedBadge(label: "API", limit: api)
                }
                if auto == nil && api == nil, let first = allLimits.first {
                    percentBadge(remaining: Int(first.percentRemaining * 100), color: first.limitColor)
                }
            }
        } else if let fiveH = fiveHourLimit {
            livePercentBadge(limit: fiveH)
        } else if let first = allLimits.max(by: { $0.percentUsed(at: Date()) < $1.percentUsed(at: Date()) }) {
            livePercentBadge(limit: first)
        }
    }

    /// Header line above an account's limits. Shows the live credential's
    /// identity (email/user id) so the label follows CLI account switches;
    /// the stored display name is kept only to disambiguate multiple accounts.
    private func accountHeader(_ usage: AccountUsageData) -> String? {
        if usages.count > 1 {
            if let identity = usage.identity,
               identity.localizedCaseInsensitiveCompare(usage.account.displayName) != .orderedSame {
                return "\(usage.account.displayName) · \(identity)"
            }
            return usage.account.displayName
        }
        return usage.identity
    }

    @ViewBuilder
    private func accountContent(_ usage: AccountUsageData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = accountHeader(usage) {
                Text(header)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(usage.identity == nil ? .uppercase : nil)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }

            if usage.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
            } else if let error = usage.error, usage.groups.isEmpty {
                // Full error state — no cached groups to show
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(usage.groups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.name)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .padding(.leading, 4)

                        ForEach(group.limits) { limit in
                            UsageLimitRow(limit: limit, accentColor: provider.brandColor)
                                .padding(.leading, 4)
                        }
                    }
                    .padding(.top, 2)
                }

                // Fetch failed but last-known groups are kept — compact footnote
                if let error = usage.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 4)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func livePercentBadge(limit: UsageLimit) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            percentBadge(
                remaining: Int(limit.percentRemaining(at: context.date) * 100),
                color: limit.limitColor(at: context.date)
            )
        }
    }

    private func percentBadge(remaining: Int, color: Color) -> some View {
        Text("\(remaining)% left")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func cursorUsedBadge(label: String, limit: UsageLimit) -> some View {
        let used = Int(limit.percentUsed * 100)
        return HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(limit.limitColor.opacity(0.7))
            Text("\(used)%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(limit.limitColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(limit.limitColor.opacity(0.12)))
    }

    private func miniLimitBadge(label: String, limit: UsageLimit) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(limit.percentRemaining(at: context.date) * 100)
            let color = limit.limitColor(at: context.date)
            HStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(color.opacity(0.7))
                Text("\(remaining)%")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
        }
    }
}

