import Foundation

struct UsageGroup: Identifiable {
    let id = UUID()
    let name: String          // e.g. "Opus 4 Limits" or "Group 1 (Gemini 3.1 Pro)"
    let limits: [UsageLimit]
}
