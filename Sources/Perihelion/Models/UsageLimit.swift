import Foundation

struct UsageLimit: Identifiable {
    let id = UUID()
    let name: String
    let percentUsed: Double        // 0.0 – 1.0
    let detail: String?            // e.g. "Resets in 2h 34m"
    let windowType: WindowType

    var percentRemaining: Double { 1.0 - percentUsed }

    enum WindowType: String {
        case fiveHour = "5-hour"
        case weekly = "Weekly"
        case daily = "Daily"
        case monthly = "Monthly"
        case unknown = ""
    }
}
