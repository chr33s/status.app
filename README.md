# status

A native macOS **menu-bar-only** app (Swift + SwiftUI) that shows your AI
subscription usage at a glance for:

- **Codex** — OpenAI
- **Claude** — Anthropic
- **Antigravity** — Google
- **GitHub Copilot** — GitHub

**No API keys.** Every provider reuses the login of its existing CLI (Claude
Code, Codex, Antigravity, GitHub). Nothing is entered by hand and nothing leaves your
Mac except requests to each provider's own API.

## Features

- Lives entirely in the menu bar (`LSUIElement`), no Dock icon, no windows.
- Tabbed strip to switch between providers; the selected tab is tinted with the
  provider's brand colour. A red dot marks a provider needing attention.
- Per-provider detail: usage meters (Session / Weekly / per-model quota, plus
  Copilot premium requests & month-to-date spend).
- **Automatic token refresh** — expired OAuth tokens are refreshed via the CLI's
  client and written back so the CLI stays in sync.
- **Re-authenticate prompt** — when a token is expired/invalid and can't be
  refreshed (or you're not signed in), the app shows a button that launches the
  CLI's login flow in Terminal.
- Quick actions: Refresh, Usage Dashboard, Status Page, Settings, Quit.
- Configurable auto-refresh interval, optional menu-bar usage badge, and
  launch-at-login (via `SMAppService`).
- Hardened Runtime enabled. **App Sandbox is disabled** — reading the CLIs'
  logins (a Keychain item and files under `~/.codex`, `~/.claude`,
  `~/.config`) isn't possible from within the sandbox, so the app ships
  non-sandboxed (not App Store distributable), like the CLIs it reads.

## Requirements

- Xcode 16 or later (the project uses Xcode 16's file-system-synchronized
  groups, `objectVersion = 77`).
- Built against the latest macOS SDK; deployment target **macOS 14.0+**.

## Build & run

```sh
open status.xcodeproj
```

Select the **status** scheme and Run (⌘R). Set your signing **Team** under
*Signing & Capabilities* on first build.

```sh
xcodebuild -project status.xcodeproj -scheme status -configuration Release build
```

## How it gets usage

Sign into each CLI once and the app picks it up automatically:

| Provider | CLI | Credential read | Usage source |
|----------|-----|-----------------|--------------|
| Claude | Claude Code (`claude`) | `Claude Code-credentials` Keychain item, or `~/.claude/.credentials.json` | OAuth probe → `anthropic-ratelimit-unified-*` headers → Session (5h) / Weekly (7d) |
| Codex | Codex CLI (`codex login`) | `~/.codex/auth.json` | ChatGPT OAuth → streamed `rate_limits.primary` / `.secondary` |
| Antigravity | Antigravity app / `agy` | `gemini` / `antigravity` Keychain item (read-only; refreshed tokens kept in memory) | Cloud Code `v1internal:retrieveUserQuotaSummary` → Gemini + Claude pools, Session (5h) / Weekly; falls back to `retrieveUserQuota` |
| Copilot | GitHub CLI (`gh auth login`) | `~/.config/github-copilot/apps.json` or `~/.config/gh/hosts.yml` | `GET /users/{login}/settings/billing/usage` |

If a CLI is configured with a plain API key instead of an OAuth login
(`OPENAI_API_KEY` in `auth.json`, `XAI_API_KEY` for Grok), the
app uses it where it can but notes that subscription limits aren't available.

## Live usage via OpenTelemetry

Alongside the on-demand probes, the app runs an **embedded OTLP/HTTP collector**
on `http://localhost:4318` and shows the token/cost counts each CLI reports as
you actually use it — a passive, vendor-sanctioned channel (no probes, no
credential handling). Claude, Codex, and Copilot export OTLP over HTTP as `application/json`.

Open **Settings → Telemetry**:

- **Claude** is configured automatically (a safe JSON merge into
  `~/.claude/settings.json`) when you toggle *Automatically configure*.
- **Antigravity** doesn't export OpenTelemetry, so it has no live usage.
- **Codex** (`~/.codex/config.toml` `[otel]`) and **Copilot** (shell `OTEL_*`
  env) show a copy-paste snippet, since we don't rewrite TOML or your shell rc.

Restart each CLI after enabling. Live token/cost then appears under each
provider in the menu (accumulated since the app launched). This is
complementary to the probe meters: telemetry gives accurate token/cost from real
usage; the probes give the subscription Session/Weekly/quota windows on demand.

> Telemetry only updates while a CLI is running, and exporters are configured for
> delta temporality so counts sum correctly. Metric names, the Codex exporter
> syntax, and Copilot's enable flag are observed and isolated in
> `OTelMetricsParser` / `OTelSetup` — verify on your Mac.

## Token refresh & re-authentication

- When an OAuth access token is expired (from its stored expiry / JWT `exp`) — or
  a request returns 401 — the app refreshes it via the CLI's OAuth client and
  **writes the rotated token back** to the same store.
- If the refresh fails (no/invalid refresh token), the provider switches to a
  **“session expired — re-authenticate”** state with a button that opens Terminal
  running the CLI's login command (`claude`, `codex login`, `agy`,
  `gh auth login --web`). The same button appears when you're not signed in.

### Caveats — please verify on your Mac

These surfaces are **undocumented**; the app reads the same data the CLIs use,
but exact endpoints, OAuth client ids, and JSON shapes are observed and may shift
between CLI releases. Each is isolated for easy adjustment:

- Claude / Codex session limits — `ClaudeProvider` / `CodexProvider` + `SessionUsage`.
- Antigravity quota — `AntigravityProvider` (`v1internal:retrieveUserQuotaSummary`,
  reverse-engineered as in [openusage](https://github.com/robinebers/openusage);
  legacy per-model buckets are pooled by worst remaining fraction).
- Copilot billing — the `gh` OAuth token may lack the **billing / "Plan"** read
  permission the usage endpoint needs, returning 403 → re-auth. If so, grant it
  with `gh auth refresh -s read:org` (or use a token with Plan access).
- OAuth clients / token endpoints / write-back — `LocalCredentials`. Writing a
  rotated refresh token back into another tool's store keeps the CLI consistent,
  but if a rotation isn't persisted correctly it could log that CLI out. Refresh
  runs only when a token is actually expired (or after a 401), writes atomically,
  and falls back to the existing token on failure.

Responses are parsed defensively via the `JSON` helper rather than rigid Codable
models, so minor schema changes are tolerated; otherwise the tab degrades to a
friendly note instead of failing.

## Project layout

```
status/
├─ StatusApp.swift          # @main, MenuBarExtra + Settings scenes
├─ Models/                     # Provider, Usage, LoadState
├─ Services/
│  ├─ LocalCredentials.swift   # reads/refreshes the four CLIs' logins
│  ├─ Reauth.swift             # launches a CLI login in Terminal
│  ├─ HTTPClient.swift         # async requests + JSON/header navigation
│  ├─ AppSettings.swift        # non-secret prefs (UserDefaults)
│  ├─ UsageStore.swift         # state, credential resolution, scheduling
│  └─ Providers/               # one fetcher per service + SessionUsage helper
└─ Views/                      # MenuBarExtra UI + Settings
```
