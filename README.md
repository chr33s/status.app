# StatusBar

A native macOS **menu-bar-only** app (Swift + SwiftUI) that shows your AI
subscription usage at a glance for:

- **Codex** — OpenAI
- **Claude** — Anthropic
- **Gemini** — Google
- **GitHub Copilot** — GitHub

- **Claude** and **Codex** reuse your existing **CLI login** (Claude Code /
  Codex CLI) to show real subscription **session** and **weekly** limits — no
  key to enter.
- **Gemini** and **Copilot** use a **read-only API key** stored in the macOS
  Keychain.

Nothing leaves your Mac except requests to each provider's own API.

## Features

- Lives entirely in the menu bar (`LSUIElement`), no Dock icon, no windows.
- Tabbed strip to switch between providers; the selected tab is tinted with the
  provider's brand colour.
- Per-provider detail: usage meters, an optional **Extra usage** budget meter,
  and a **Cost** summary (today + last 30 days, spend and tokens).
- Quick actions: Refresh, Add Account, Usage Dashboard, Status Page, Settings,
  About, Quit.
- Configurable auto-refresh interval, optional menu-bar usage badge, and
  launch-at-login (via `SMAppService`).
- Hardened Runtime enabled. **App Sandbox is disabled** — reading the Claude
  Code / Codex CLI logins (a Keychain item and files under `~/.codex` /
  `~/.claude`) isn't possible from within the sandbox, so the app ships
  non-sandboxed (not App Store distributable), like the CLIs it reads.

## Requirements

- Xcode 16 or later (the project uses Xcode 16's file-system-synchronized
  groups, `objectVersion = 77`).
- Built against the latest macOS SDK; deployment target **macOS 14.0+**.

## Build & run

```sh
open StatusBar.xcodeproj
```

Select the **StatusBar** scheme and Run (⌘R). Set your signing **Team** under
*Signing & Capabilities* on first build (required for Keychain + sandbox).

You can also build from the command line:

```sh
xcodebuild -project StatusBar.xcodeproj -scheme StatusBar -configuration Release build
```

## Configuration

| Provider | Auth | Usage source |
|----------|------|--------------|
| Claude | **Claude Code login** (read automatically) | OAuth probe → `anthropic-ratelimit-unified-*` headers → Session (5h) / Weekly (7d) meters |
| Codex | **Codex CLI login** (read automatically) | ChatGPT OAuth → `rate_limits.primary` / `.secondary` windows |
| Gemini (Google) | AI Studio API key | `GET /v1beta/models` (connectivity); usage lives in Cloud billing |
| GitHub Copilot | Fine-grained token, read-only billing | `GET /users/{login}/settings/billing/usage` |

- **Claude / Codex** need no setup beyond being signed into the respective CLI
  (`claude` / `codex`). The app reads:
  - Claude — the `Claude Code-credentials` Keychain item, or
    `~/.claude/.credentials.json`.
  - Codex — `~/.codex/auth.json`.

  When an OAuth access token is expired (detected from its stored expiry / JWT
  `exp`) — or a request returns 401 — the app refreshes it via the CLI's OAuth
  client and **writes the rotated token back** to the same store so the CLI stays
  in sync. See the caveat below.
- **Gemini / Copilot** — open **Settings… → Providers** and paste a read-only
  key. Optional identifier (Cloud project / GitHub username, auto-detected) and
  monthly budget (drives the *Extra usage* meter).

### Caveats on the CLI session limits

The subscription **session-limit** surfaces for Claude and Codex are not public,
documented APIs — the app reads the same data the CLIs themselves use. The exact
endpoints, headers, and response shapes are therefore **best-effort** and may
shift between CLI releases. They're each isolated in one place
(`ClaudeProvider` / `CodexProvider`, with the `rate_limits` parsing in
`SessionUsage`) so they're easy to adjust, and the app degrades to a friendly
"signed in — limits unavailable" note rather than failing. Verify behaviour on
your Mac and tweak the endpoint constants if a CLI update changes them.

**Token refresh / write-back.** Refreshing a rotating OAuth token and writing it
back into another tool's store (`LocalCredentials`) keeps the CLI consistent,
but the OAuth client ids, token endpoints, and stored JSON shapes are observed
rather than documented. If a refresh-token rotation isn't persisted correctly it
could log the corresponding CLI out. Refresh only runs when a token is actually
expired (or after a 401), writes back atomically, and falls back to the existing
token on failure — but please confirm it behaves on your Mac before relying on it.

The Gemini / Copilot API fetchers parse responses defensively via the `JSON`
helper rather than rigid Codable models, so minor schema changes are tolerated.

## Project layout

```
StatusBar/
├─ StatusBarApp.swift          # @main, MenuBarExtra + Settings scenes
├─ Models/                     # Provider, Usage, LoadState
├─ Services/
│  ├─ Keychain.swift           # read-only API-key storage (Gemini/Copilot)
│  ├─ LocalCredentials.swift   # reads Claude Code / Codex CLI logins
│  ├─ HTTPClient.swift         # async requests + JSON/header navigation
│  ├─ AppSettings.swift        # non-secret prefs (UserDefaults)
│  ├─ UsageStore.swift         # state, credential resolution, scheduling
│  └─ Providers/               # one fetcher per service + SessionUsage helper
└─ Views/                      # MenuBarExtra UI + Settings
```
