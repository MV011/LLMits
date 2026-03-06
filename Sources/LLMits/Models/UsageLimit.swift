import Foundation
import SwiftUI

struct UsageLimit: Identifiable {
    let id = UUID()
    let name: String
    let percentUsed: Double        // 0.0 – 1.0
    let detail: String?            // e.g. "Resets in 2h 34m"
    let windowType: WindowType

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
        case monthly = "Monthly"
        case unknown = ""
    }
}
