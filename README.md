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
| **xAI (Grok Build)** | Auto-discovered from `~/.grok/auth.json` | Shared weekly usage pool (unified billing, June 2026+), extra / on-demand credits |
| **Kimi Code** | Auto-discovered from `~/.kimi-code/credentials` | Weekly quota, rolling 5-hour rate window |

## Features

- **Zero-config setup** — auto-discovers credentials from installed CLI tools
- **Collapsed cards** — see all providers at a glance with key metrics
- **Red alerts** — cards turn red when limits are exhausted, with countdown timers
- **Auto-refresh** — usage data refreshes every 10 minutes; countdowns tick locally from the last synced reset time
- **Last-synced cache** — last API snapshot is stored in `~/Library/Application Support/LLMits/usage.sqlite` so the popover opens with the previous numbers immediately
- **Token refresh** — self-refreshes expired OAuth tokens (Grok, Antigravity); Claude tokens are refreshed by Claude Code itself and re-read from the Keychain
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
- **Grok Build** — reads OAuth session from `~/.grok/auth.json`
- **Kimi Code** — reads OAuth token from `~/.kimi-code/credentials/kimi-code.json`

### Local Code Signing

`build.sh` signs the app with a self-signed **"LLMits Local Signing"** certificate
(created automatically in your login keychain by `scripts/create-signing-identity.sh`,
no Apple Developer account needed). A stable signing identity lets macOS persist
Keychain **"Always Allow"** grants across rebuilds — with ad-hoc signing, macOS
asks for the keychain password on every Claude credential read instead.

The first launch after the identity is created (or after Claude re-creates its
keychain item on re-login) shows one "Always Allow" prompt — click it once and
you won't be asked for a password again.

### Manual Token Entry

If auto-discovery doesn't work, click **"+ Add Account"** in the popover to manually add a provider with a token or cookie string.

## Project Structure

```
Sources/LLMitsApp/          # @main menu-bar entry (depends on LLMitsCore)
Sources/LLMits/             # LLMitsCore library
├── Models/                 # Account, Provider, UsageLimit (resetAt), UsageGroup
├── Views/                  # MenuBarPopover, ProviderSection, live countdown rows
├── ViewModels/             # AccountsViewModel, UsageDashboardViewModel
├── Services/               # API services per provider + last-synced SQLite cache
│   ├── GrokBillingParser.swift    # Unified weekly + legacy monthly billing
│   ├── GrokService.swift          # Grok Build auth.json + billing API
│   ├── KimiUsageParser.swift      # Kimi usages response (resetAt, 5h + weekly)
│   ├── KimiService.swift          # Kimi Code credentials + usages API
│   ├── UsageSnapshotStore.swift   # SQLite last-synced usage cache
│   └── …
└── Resources/              # Provider SVG icons
Tests/LLMitsCheck/          # Parser + snapshot assertions (`swift run LLMitsCheck`)
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
