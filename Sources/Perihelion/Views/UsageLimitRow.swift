import SwiftUI

struct UsageLimitRow: View {
    let limit: UsageLimit
    var accentColor: Color = .blue

    private var barColor: Color {
        let used = limit.percentUsed
        if used < 0.5 { return .green }
        if used < 0.75 { return .yellow }
        if used < 0.9 { return .orange }
        return .red
    }

    private var remainingText: String {
        "\(Int(limit.percentRemaining * 100))% left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer()
                Text(remainingText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(barColor)
            }

            // Progress bar
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
                        .frame(width: max(2, geo.size.width * limit.percentUsed))
                        .animation(.spring(duration: 0.5), value: limit.percentUsed)
                }
            }
            .frame(height: 6)

            // Detail row
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
                if let detail = limit.detail {
                    HStack(spacing: 3) {
                        if detail.lowercased().contains("reset") {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 8))
                        }
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
