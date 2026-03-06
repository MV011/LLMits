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
        allLimits.contains { $0.windowType == .weekly && $0.percentUsed >= 1.0 }
    }

    /// Priority 2: 5-hour window exhausted
    private var isFiveHourExhausted: Bool {
        allLimits.contains { $0.windowType == .fiveHour && $0.percentUsed >= 1.0 }
    }

    /// For multi-model providers (Antigravity): ALL pinned models exhausted
    private var isAllPinnedExhausted: Bool {
        guard provider == .antigravity else { return false }
        let pro = allLimits.first { $0.name.lowercased().contains("3.1 pro") && $0.name.lowercased().contains("high") }
            ?? allLimits.first { $0.name.lowercased().contains("pro") }
        let opus = allLimits.first { $0.name.lowercased().contains("opus") }
        guard let p = pro, let o = opus else { return false }
        return p.percentUsed >= 1.0 && o.percentUsed >= 1.0
    }

    /// Combined: should the card be red?
    private var isAtLimit: Bool {
        isWeeklyExhausted || isFiveHourExhausted || isAllPinnedExhausted
    }

    /// Reset detail for the exhausted limit
    private var exhaustedResetDetail: String? {
        if isWeeklyExhausted {
            return allLimits.first { $0.windowType == .weekly && $0.percentUsed >= 1.0 }?.detail
        }
        if isFiveHourExhausted {
            return allLimits.first { $0.windowType == .fiveHour && $0.percentUsed >= 1.0 }?.detail
        }
        if isAllPinnedExhausted {
            return (allLimits.first { $0.name.lowercased().contains("pro") && $0.percentUsed >= 1.0 })?.detail
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
        if isAtLimit, let resetDetail = exhaustedResetDetail {
            // Limit exhausted — show reset countdown in red
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 8))
                Text(resetDetail.replacingOccurrences(of: "Resets in ", with: ""))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.12)))
        } else if provider == .antigravity {
            // Show two key model limits: Gemini Pro + Claude Opus
            let proLimit = allLimits.first { $0.name.lowercased().contains("3.1 pro") && $0.name.lowercased().contains("high") }
                ?? allLimits.first { $0.name.lowercased().contains("pro") }
            let opusLimit = allLimits.first { $0.name.lowercased().contains("opus") }

            HStack(spacing: 4) {
                if let pro = proLimit {
                    miniLimitBadge(label: "Pro", limit: pro)
                }
                if let opus = opusLimit {
                    miniLimitBadge(label: "Opus", limit: opus)
                }
            }
        } else if let fiveH = fiveHourLimit {
            percentBadge(remaining: Int(fiveH.percentRemaining * 100), color: fiveH.limitColor)
        } else {
            let maxUsed = allLimits.map(\.percentUsed).max() ?? 0
            let maxLimit = allLimits.first { $0.percentUsed == maxUsed }
            percentBadge(remaining: Int((1.0 - maxUsed) * 100), color: maxLimit?.limitColor ?? .green)
        }
    }

    @ViewBuilder
    private func accountContent(_ usage: AccountUsageData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if usages.count > 1 {
                Text(usage.account.displayName)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
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
            } else if let error = usage.error {
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
            }
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

    private func miniLimitBadge(label: String, limit: UsageLimit) -> some View {
        let remaining = Int(limit.percentRemaining * 100)

        return HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(limit.limitColor.opacity(0.7))
            Text("\(remaining)%")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(limit.limitColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(limit.limitColor.opacity(0.12)))
    }
}

