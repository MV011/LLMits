import SwiftUI

enum Provider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case antigravity
    case geminiCLI
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (Codex / ChatGPT)"
        case .antigravity: return "Antigravity (Gemini)"
        case .geminiCLI: return "Gemini CLI"
        case .cursor: return "Cursor"
        }
    }

    @ViewBuilder
    var icon: some View {
        if let url = Bundle.module.url(forResource: iconResourceName, withExtension: "svg"),
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

    /// Resource name for the SVG icon (decoupled from rawValue for cases like geminiCLI)
    private var iconResourceName: String {
        switch self {
        case .geminiCLI: return "gemini"
        default: return rawValue
        }
    }

    var brandColor: Color {
        switch self {
        case .anthropic: return Color(red: 0.82, green: 0.55, blue: 0.36)   // warm tan
        case .openai: return Color(red: 0.34, green: 0.76, blue: 0.67)      // teal
        case .antigravity: return Color(red: 0.26, green: 0.52, blue: 0.96) // blue
        case .geminiCLI: return Color(red: 0.42, green: 0.68, blue: 0.91)   // lighter blue
        case .cursor: return Color(red: 0.60, green: 0.40, blue: 0.90)      // purple
        }
    }

    var tokenLabel: String {
        switch self {
        case .anthropic: return "Session Token (from claude.ai)"
        case .openai: return "Session Token (from chatgpt.com)"
        case .antigravity: return "Session Token (from antigravity.google)"
        case .geminiCLI: return "Auto-discovered from ~/.gemini (no token needed)"
        case .cursor: return "Session Token (from cursor.com)"
        }
    }

    /// Whether this provider auto-discovers credentials (no manual token paste)
    var isAutoDiscovered: Bool {
        switch self {
        case .geminiCLI: return true
        default: return false
        }
    }
}
