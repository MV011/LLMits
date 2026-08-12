import SwiftUI

struct UsageLimitRow: View {
    let limit: UsageLimit
    var accentColor: Color = .blue

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(at: context.date)
        }
    }

    private func row(at date: Date) -> some View {
        let used = limit.percentUsed(at: date)
        let barColor = limit.limitColor(at: date)
        let percentLabel: String = {
            switch limit.percentDisplay {
            case .remaining:
                return "\(Int(limit.percentRemaining(at: date) * 100))% left"
            case .used:
                return "\(Int(used * 100))%"
            }
        }()

        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(percentLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(barColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.06))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.6), barColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geo.size.width * used))
                        .animation(.spring(duration: 0.5), value: used)
                }
            }
            .frame(height: 6)

            HStack(spacing: 4) {
                if !limit.windowType.rawValue.isEmpty {
                    Text(limit.windowType.rawValue)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(accentColor.opacity(0.08))
                        )
                }
                Spacer()
                if let detail = limit.detail, !detail.lowercased().contains("reset") {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let countdown = limit.resetDetail(at: date) {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 8))
                        Text(countdown)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
