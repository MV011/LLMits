import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case antigravity
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (Codex / ChatGPT)"
        case .antigravity: return "Antigravity (Gemini)"
        case .cursor: return "Cursor"
        }
    }

    @ViewBuilder
    var icon: some View {
        if let url = Bundle.module.url(forResource: self.rawValue, withExtension: "svg"),
           let nsImage = NSImage(contentsOf: url) {
            
            Image(nsImage: nsImage)
                .resizable()
                .renderingMode(.template)
                .foregroundColor(brandColor)
            
        } else {
            // Fallback if resource fails
            Image(systemName: "questionmark.app")
                .resizable()
                .foregroundColor(.red)
        }
    }

    var brandColor: Color {
        switch self {
        case .anthropic: return Color(red: 0.82, green: 0.55, blue: 0.36)   // warm tan
        case .openai: return Color(red: 0.34, green: 0.76, blue: 0.67)      // teal
        case .antigravity: return Color(red: 0.26, green: 0.52, blue: 0.96) // blue
        case .cursor: return Color(red: 0.60, green: 0.40, blue: 0.90)      // purple
        }
    }

    var tokenLabel: String {
        switch self {
        case .anthropic: return "Session Token (from claude.ai)"
        case .openai: return "Session Token (from chatgpt.com)"
        case .antigravity: return "Session Token (from antigravity.google)"
        case .cursor: return "Session Token (from cursor.com)"
        }
    }
}
