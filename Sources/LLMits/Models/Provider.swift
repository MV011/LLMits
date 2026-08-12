import SwiftUI

public enum Provider: String, Codable, CaseIterable, Identifiable {
    case anthropic
    case openai
    case antigravity
    case cursor
    case grok
    case kimi

    public var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        case .openai: return "OpenAI (Codex / ChatGPT)"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .grok: return "xAI (Grok Build)"
        case .kimi: return "Kimi Code"
        }
    }

    /// Loaded icons are cached — NSImage(contentsOf:) does a disk read + SVG
    /// parse, so it must not run on every render (the Add sheet draws 6 icons
    /// per keystroke).
    private static var iconCache: [Provider: NSImage] = [:]

    @ViewBuilder
    var icon: some View {
        if let nsImage = cachedIcon {

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

    private var cachedIcon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        guard let url = Bundle.module.url(forResource: iconResourceName, withExtension: "svg"),
              let nsImage = NSImage(contentsOf: url) else { return nil }
        Self.iconCache[self] = nsImage
        return nsImage
    }

    /// Resource name for the SVG icon (decoupled from rawValue for cases like geminiCLI)
    private var iconResourceName: String {
        switch self {
        case .antigravity: return "antigravity"
        default: return rawValue
        }
    }

    var brandColor: Color {
        switch self {
        case .anthropic: return Color(red: 0.82, green: 0.55, blue: 0.36)   // warm tan
        case .openai: return Color(red: 0.34, green: 0.76, blue: 0.67)      // teal
        case .antigravity: return Color(red: 0.26, green: 0.52, blue: 0.96) // blue
        case .cursor: return Color(red: 0.60, green: 0.40, blue: 0.90)      // purple
        case .grok: return Color(red: 0.0, green: 0.0, blue: 0.0)           // black (xAI)
        case .kimi: return Color(red: 0.35, green: 0.34, blue: 0.84)        // indigo (Moonshot)
        }
    }

    var tokenLabel: String {
        switch self {
        case .anthropic: return "Session Token (from claude.ai)"
        case .openai: return "Session Token (from chatgpt.com)"
        case .antigravity: return "Auto-discovered from ~/.gemini (no token needed)"
        case .cursor: return "Session Token (from cursor.com)"
        case .grok: return "Auto-discovered from ~/.grok/auth.json (Grok Build)"
        case .kimi: return "Auto-discovered from ~/.kimi-code/credentials (Kimi Code CLI)"
        }
    }

    /// Whether this provider auto-discovers credentials (no manual token paste)
    var isAutoDiscovered: Bool {
        switch self {
        case .antigravity, .grok, .kimi: return true
        default: return false
        }
    }
}
