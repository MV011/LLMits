import Foundation
import SwiftUI

struct UsageLimit: Identifiable {
    let id = UUID()
    let name: String
    let percentUsed: Double        // 0.0 – 1.0
    let detail: String?            // e.g. "Resets in 2h 34m"
    let windowType: WindowType
    /// `.remaining` shows "62% left" (Anthropic/OpenAI). `.used` shows "38%" like Cursor's dashboard.
    let percentDisplay: PercentDisplay

    init(
        name: String,
        percentUsed: Double,
        detail: String? = nil,
        windowType: WindowType,
        percentDisplay: PercentDisplay = .remaining
    ) {
        self.name = name
        self.percentUsed = percentUsed
        self.detail = detail
        self.windowType = windowType
        self.percentDisplay = percentDisplay
    }

    enum PercentDisplay {
        case remaining
        case used
    }

    var percentRemaining: Double { 1.0 - percentUsed }

    /// Color representing the usage level — shared across all views.
    var limitColor: Color {
        if percentUsed < 0.5 { return .green }
        if percentUsed < 0.75 { return .yellow }
        if percentUsed < 0.9 { return .orange }
        return .red
    }

    enum WindowType: String {
        case fiveHour = "5-hour"
        case weekly = "Weekly"
        case daily = "Daily"
        case perDay = "Per-day"
        case monthly = "Monthly"
        case unknown = ""
    }
}
