import Foundation
import SwiftUI

public struct UsageLimit: Identifiable, Codable, Equatable {
    // Stable, content-derived id (names are unique within a group) so
    // SwiftUI doesn't rebuild the whole list subtree on every refresh.
    public var id: String { name }
    public let name: String
    public let percentUsed: Double        // 0.0 – 1.0 as reported at fetch time
    public let detail: String?            // static extras (used/limit, plan notes) — not countdowns
    public let resetAt: Date?             // absolute window end; countdown is derived live
    public let windowType: WindowType
    /// `.remaining` shows "62% left" (Anthropic/OpenAI). `.used` shows "38%" like Cursor's dashboard.
    public let percentDisplay: PercentDisplay

    public init(
        name: String,
        percentUsed: Double,
        detail: String? = nil,
        resetAt: Date? = nil,
        windowType: WindowType,
        percentDisplay: PercentDisplay = .remaining
    ) {
        self.name = name
        self.percentUsed = percentUsed
        self.detail = detail
        self.resetAt = resetAt
        self.windowType = windowType
        self.percentDisplay = percentDisplay
    }

    public enum PercentDisplay: String, Codable, Equatable {
        case remaining
        case used
    }

    /// If the stored reset has already passed, treat the window as unused
    /// until the next API snapshot arrives.
    public func percentUsed(at date: Date) -> Double {
        if let resetAt, resetAt <= date { return 0 }
        return percentUsed
    }

    func percentRemaining(at date: Date) -> Double {
        1.0 - percentUsed(at: date)
    }

    var percentRemaining: Double { 1.0 - percentUsed }

    func limitColor(at date: Date = Date()) -> Color {
        let used = percentUsed(at: date)
        if used < 0.5 { return .green }
        if used < 0.75 { return .yellow }
        if used < 0.9 { return .orange }
        return .red
    }

    var limitColor: Color { limitColor(at: Date()) }

    public func resetDetail(at date: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        return TimeFormatter.formatRemaining(resetAt.timeIntervalSince(date))
    }

    public enum WindowType: String, Codable {
        case fiveHour = "5-hour"
        case weekly = "Weekly"
        case daily = "Daily"
        case perDay = "Per-day"
        case monthly = "Monthly"
        case unknown = ""
    }
}
