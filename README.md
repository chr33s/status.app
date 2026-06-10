# StatusBar

A native macOS **menu-bar-only** app (Swift + SwiftUI) that shows your AI
subscription usage at a glance for:

- **Codex** — OpenAI
- **Claude** — Anthropic
- **Gemini** — Google
- **GitHub Copilot** — GitHub

API keys are entered once and stored **read-only in the macOS Keychain**. They
never leave your Mac except in requests to each provider's own API.

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
- App Sandbox enabled, hardened runtime, network-client entitlement only.

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

Open **Settings… → Providers** and paste a key for each service you want to
track. All keys should be **read-only**:

| Provider | Key type | Usage source |
|----------|----------|--------------|
| Codex (OpenAI) | Admin API key `sk-admin-…` | `GET /v1/organization/costs`, `…/usage/completions` |
| Claude (Anthropic) | Admin API key `sk-ant-admin…` | `GET /v1/organizations/cost_report`, `…/usage_report/messages` |
| Gemini (Google) | AI Studio API key | `GET /v1beta/models` (connectivity); usage lives in Cloud billing |
| GitHub Copilot | Fine-grained token, read-only billing | `GET /users/{login}/settings/billing/usage` |

Optional per-provider fields:

- **Identifier** — org ID (OpenAI/Anthropic), Cloud project (Gemini), or GitHub
  username (auto-detected from the token if blank).
- **Monthly budget (USD)** — drives the *Extra usage* meter.

### Notes on usage APIs

- OpenAI and Anthropic expose spend and token usage only through their
  **organization-level Admin APIs**, so an admin key is required to see figures.
- Google does not expose per-key usage through a simple API key; the Gemini tab
  validates the key and links to the dashboard. Set a budget to track a cap
  manually.
- GitHub's enhanced billing usage endpoint reports Copilot premium-request
  quantity and net spend for the current month.

If a provider's API shape changes, the relevant fetcher in
`StatusBar/Services/Providers/` is the single place to adjust — responses are
parsed defensively via the `JSON` helper rather than rigid models.

## Project layout

```
StatusBar/
├─ StatusBarApp.swift          # @main, MenuBarExtra + Settings scenes
├─ Models/                     # Provider, Usage, LoadState
├─ Services/
│  ├─ Keychain.swift           # read-only secret storage
│  ├─ HTTPClient.swift         # async GET + JSON navigation
│  ├─ AppSettings.swift        # non-secret prefs (UserDefaults)
│  ├─ UsageStore.swift         # state + refresh scheduling
│  └─ Providers/               # one fetcher per service
└─ Views/                      # MenuBarExtra UI + Settings
```
