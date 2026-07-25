import Foundation

struct UsageGroup: Identifiable {
    // Stable, content-derived id (names are unique within an account) so
    // SwiftUI doesn't rebuild the whole list subtree on every refresh.
    var id: String { name }
    let name: String          // e.g. "Opus 4 Limits" or "Group 1 (Gemini 3.1 Pro)"
    let limits: [UsageLimit]
}
