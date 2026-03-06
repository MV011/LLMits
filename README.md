# LLMits

A lightweight macOS menu bar app that tracks your AI coding tool usage and limits across multiple providers — all in one glance.

<p align="center">
  <strong>LLM + Limits = LLMits</strong>
</p>

## Supported Providers

| Provider | Auth Method | What's Tracked |
|----------|------------|----------------|
| **Anthropic** (Claude Code) | Auto-discovered from Keychain | Weekly Opus/Sonnet limits, 5h session windows, monthly spend |
| **OpenAI** (Codex CLI) | Auto-discovered from `~/.codex/auth.json` | 5h session limits, weekly limits, code review, credit balance |
| **Cursor** | Auto-discovered from local SQLite DB | Premium requests, extra usage |
| **Antigravity** | Auto-discovered from running server | Per-model quotas with 5h reset windows |

## Features

- **Zero-config setup** — auto-discovers credentials from installed CLI tools
- **Collapsed cards** — see all providers at a glance with key metrics
- **Red alerts** — cards turn red when limits are exhausted, with countdown timers
- **Auto-refresh** — usage data refreshes every 5 minutes
- **Token refresh** — automatically refreshes expired OAuth tokens (Anthropic)
- **Native macOS** — lightweight SwiftUI menu bar app, no Electron

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6.0+ toolchain
- At least one supported AI tool installed and logged in

## Quick Start

### Build & Run

```bash
git clone https://github.com/MV011/LLMits.git
cd LLMits

# Quick dev build
swift build && .build/debug/LLMits

# Build .app bundle and install to /Applications
./build.sh --release --install

# Launch from Applications
open /Applications/LLMits.app
```

The app appears as a gauge icon (⏱) in your menu bar. Click it to see your usage dashboard.

### Launch at Login

Open the settings page (⚙ icon) and toggle **"Launch at Login"** — uses macOS native login items, no launchd plists needed.

### Auto-Discovery

LLMits automatically finds your credentials — no manual setup required:

- **Claude Code** — reads OAuth tokens from the macOS Keychain (`Claude Code-credentials` entry)
- **Codex CLI** — reads from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
- **Cursor** — reads JWT from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- **Antigravity** — discovers running language server processes via `ps`

### Manual Token Entry

If auto-discovery doesn't work, click **"+ Add Account"** in the popover to manually add a provider with a token or cookie string.

## Project Structure

```
Sources/Perihelion/
├── App/                    # App entry point (LLMitsApp)
├── Models/                 # Data models (Account, Provider, UsageLimit)
├── Views/                  # SwiftUI views (MenuBarPopover, ProviderSection)
├── ViewModels/             # View models (AccountsViewModel, UsageDashboardViewModel)
├── Services/               # API services per provider + utilities
│   ├── AnthropicService.swift    # Claude Code OAuth + usage API
│   ├── OpenAIService.swift       # Codex CLI usage API
│   ├── CursorService.swift       # Cursor SQLite + cookie auth
│   ├── AntigravityService.swift  # Local server discovery + quota API
│   ├── KeychainManager.swift     # File-based token storage
│   ├── TokenCache.swift          # In-memory credential cache
│   └── TimeFormatter.swift       # Reset countdown formatting
└── Resources/              # Provider SVG icons
```

## Debug Logging

To enable debug logs:

```bash
touch /tmp/llmits_debug.log
```

Then check the log:

```bash
tail -f /tmp/llmits_debug.log
```

## License

MIT
