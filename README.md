# status

A native macOS **menu-bar-only** app (Swift + SwiftUI) that shows your AI
subscription usage at a glance for:

- **Codex** — OpenAI
- **Claude** — Anthropic
- **Antigravity** — Google
- **GitHub Copilot** — GitHub
- **Grok** — xAI

**No API keys.** Every provider reuses the login of its existing CLI (Claude
Code, Codex, Antigravity, GitHub). Nothing is entered by hand and nothing leaves your
Mac except requests to each provider's own API.

## Features

- Lives entirely in the menu bar (`LSUIElement`), no Dock icon, no windows.
- Tabbed strip to switch between providers; the selected tab is tinted with the
  provider's brand colour. A red dot marks a provider needing attention.
- Per-provider detail: usage meters (Session / Weekly / per-model quota, plus
  Copilot premium requests and Grok extra-usage caps).
- **Automatic token refresh** — expired OAuth tokens are refreshed via the CLI's
  client and written back so the CLI stays in sync.
- **Sign-in prompt** — when a token is expired/invalid and can't be refreshed
  (or you're not signed in), the app shows the CLI's login command with **Copy**
  and **Copy & Open Terminal**. You paste and run it yourself, then choose
  **Re-check**.
- Quick actions: Refresh, Usage Dashboard, Status Page, Settings, Quit.
- Configurable auto-refresh interval, optional menu-bar usage badge, and
  launch-at-login (via `SMAppService`).
- Hardened Runtime and **App Sandbox enabled**, with no temporary sandbox
  exceptions. The app only reads a CLI's folder (`~/.claude`, `~/.codex`,
  `~/.grok`, `~/.config/gh`) after you choose it in a folder picker, and
  remembers that grant with a security-scoped bookmark.

## Requirements

- Xcode 16 or later (the project uses Xcode 16's file-system-synchronized
  groups, `objectVersion = 77`).
- Built against the latest macOS SDK; deployment target **macOS 26.0+**.

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

Sign into each CLI once. The first time a provider needs its CLI's folder, its
tab shows **Access required** with a **Choose … Folder** button; pick the folder
(hidden dot-folders are shown in the picker) and the app reads the login from
there. The grant is remembered across launches — change or remove it under
**Settings → Providers**. If the folder is moved or deleted, the tab shows
**Access needs to be granted again**. Access required is never reported as
“Not signed in”. Antigravity (Keychain only) needs no folder, and neither do
Claude, Copilot, or Codex when their login is in the Keychain (for Codex, set
`cli_auth_credentials_store = "keyring"` in `~/.codex/config.toml` and sign in
again). Keychain-held Codex and Claude logins are never refreshed by Status —
their refresh tokens are single-use — so an expired one shows **Session
expired** until the CLI itself refreshes it.

Claude Code's Keychain item is read by running
`security find-generic-password -s "Claude Code-credentials" -w` rather than
through the Keychain API. Each time the CLI rotates its token it rewrites the
item with `security add-generic-password -U`, and macOS resets the item's
partition list to the writer's (`apple-tool:`) while keeping the trusted-app
list — so an app that was granted **Always Allow** is prompted for the keychain
password again after every rotation. The `security` tool is the item's creator
and is never dropped from that list, so reading through it never prompts. The
direct Keychain read remains only as a fallback.

| Provider | CLI | Credential read | Usage source |
|----------|-----|-----------------|--------------|
| Claude | Claude Code (`claude`) | `Claude Code-credentials` Keychain item, read through `/usr/bin/security` (see below), or `~/.claude/.credentials.json` | OAuth probe → `anthropic-ratelimit-unified-*` headers → Session (5h) / Weekly (7d) |
| Codex | Codex CLI (`codex login`) | `Codex Auth` Keychain item (with `cli_auth_credentials_store = "keyring"`), else `~/.codex/auth.json` in a granted `~/.codex`; when both exist the newer `last_refresh` wins | ChatGPT OAuth → `x-codex-primary-*` / `x-codex-secondary-*` response headers |
| Antigravity | Antigravity app / `agy` | `gemini` / `antigravity` Keychain item (read-only; refreshed tokens kept in memory) | Cloud Code `v1internal:retrieveUserQuotaSummary` → Gemini + Claude pools, Session (5h) / Weekly; falls back to `retrieveUserQuota` |
| Grok | Grok CLI (`grok login`) | OIDC entries in a granted `~/.grok/auth.json`, or `XAI_API_KEY` / `GROK_API_KEY` in the app environment | `GET /v1/billing?format=credits` → weekly shared pool and extra-usage cap |
| Copilot | Copilot CLI (`copilot login`) or GitHub CLI (`gh auth login`) | `copilot-cli` or `gh:github.com` Keychain item; else `apps.json` / `hosts.json` in a granted `~/.config/github-copilot`, or `hosts.yml` in a granted `~/.config/gh` | `GET /copilot_internal/user` → premium requests / chat / completions quotas |

### Sandbox & folder access

Everything Status touches outside its container is a user-granted CLI folder
(`ExternalResource` in `SecurityScopedAccess.swift`). All reads and writes run
inside `SecurityScopedAccess.withAccess(to:)`, which resolves the bookmark,
refreshes it if stale, and brackets the work with
`start/stopAccessingSecurityScopedResource()`. Bookmarks are app-scoped and
stored in `UserDefaults`; folders are requested only when a provider needs one,
never all at first launch.

| Resource | Folder | Files | Access |
|----------|--------|-------|--------|
| `claudeData` | `~/.claude` | `.credentials.json` (Keychain fallback); `settings.json` (telemetry auto-config) | read; read/write |
| `codexData` | `~/.codex` | `auth.json` | read + write-back of refreshed tokens |
| `grokData` | `~/.grok` | `auth.json` | read + write-back of refreshed tokens |
| `githubConfig` | `~/.config/gh` or `~/.config/github-copilot` | `hosts.yml` / `apps.json` / `hosts.json` | read |

A selected folder is checked against the resource's expected structure before
it's saved (an empty folder with the right name is accepted). Folder
authorization is kept separate from sign-in state:

| State | Shown as |
|-------|----------|
| No bookmark | **Access required** + *Choose … Folder* |
| Bookmark invalid / folder moved | **Access needs to be granted again** |
| Authorized, no credential | **Not signed in** + CLI login command |
| Authorized, expired and not refreshable | **Session expired** + CLI login command |

Existing CLI credentials are never copied into the app's container.

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
  `~/.claude/settings.json`) when you toggle *Auto-configure Claude*; the
  first time, the app asks you to choose your `.claude` folder.
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

- When a request returns 401/403, the app re-reads the CLI login and retries
  with a newer token if available. For file-backed Codex and Grok logins it
  can exchange the refresh token and **write the rotation back**; a concurrent
  CLI login wins over that exchange. Claude and Keychain-backed Codex logins
  are only re-read. Antigravity refreshes are held in memory. Grok also detects
  expired JWTs before requesting usage.
- If the refresh fails (no/invalid refresh token), the provider switches to a
  **“Session expired”** state showing the CLI's login command (`claude auth
  login`, `codex login --device-auth`, `agy`, `copilot login`, `grok login`).
  **Copy & Open Terminal** copies it (no trailing newline) and launches Terminal
  via `NSWorkspace`; **Copy** is for other terminal apps. The app never types,
  pastes, or runs anything in Terminal and doesn't send it Apple Events — you
  run the command, then choose **Re-check**. The same prompt appears when
  you're not signed in.

### Caveats — please verify on your Mac

These surfaces are **undocumented**; the app reads the same data the CLIs use,
but exact endpoints, OAuth client ids, and JSON shapes are observed and may shift
between CLI releases. Each is isolated for easy adjustment:

- Claude / Codex session limits — `ClaudeProvider` / `CodexProvider` + `SessionUsage`.
- Antigravity quota — `AntigravityProvider` (`v1internal:retrieveUserQuotaSummary`,
  reverse-engineered as in [openusage](https://github.com/robinebers/openusage);
  legacy per-model buckets are pooled by worst remaining fraction).
- Copilot quotas — the internal entitlement endpoint expects a recognised
  Copilot client identity. A 401/403 asks for a fresh CLI login; adding `read:org`
  is not a billing-permission fix.
- OAuth clients / token endpoints / write-back — `LocalCredentials`. Writing a
  rotated refresh token back into another tool's store keeps the CLI consistent,
  but if a rotation isn't persisted correctly it could log that CLI out. Refresh
  runs after an authentication failure, writes atomically, and reports a
  failed write-back instead of claiming that the CLI store was updated.

Responses are parsed defensively via the `JSON` helper rather than rigid Codable
models, so minor schema changes are tolerated; otherwise the tab degrades to a
friendly note instead of failing.

## Project layout

```
status/
├─ StatusApp.swift          # @main, MenuBarExtra + Settings scenes
├─ Models/                     # Provider, Usage, LoadState
├─ Services/
│  ├─ LocalCredentials.swift   # reads/refreshes the CLIs' logins
│  ├─ SecurityScopedAccess.swift # user-granted CLI folders (bookmarks)
│  ├─ Reauth.swift             # copies a CLI login command, opens Terminal
│  ├─ HTTPClient.swift         # async requests + JSON/header navigation
│  ├─ AppSettings.swift        # non-secret prefs (UserDefaults)
│  ├─ UsageStore.swift         # state, credential resolution, scheduling
│  └─ Providers/               # one fetcher per service + SessionUsage helper
└─ Views/                      # MenuBarExtra UI + Settings
```

## App Review notes

> Status is sandboxed. It does not automate or send Apple Events to Terminal.
> When CLI authentication is required, Status displays and copies the login
> command and can launch Terminal using NSWorkspace; the user manually pastes
> and executes the command.
>
> Status accesses existing CLI configuration only after the user explicitly
> selects the corresponding CLI data folder. Access is persisted using macOS
> security-scoped bookmarks. The app no longer requests temporary
> home-relative filesystem exceptions.

Reviewer steps — folder authorization:

1. Install the Codex CLI and run `codex login` (creates `~/.codex/auth.json`).
2. Launch Status and open its menu-bar item; select the **Codex** tab. It shows
   **Access required** (not “Not signed in”).
3. Click **Choose .codex Folder**; the picker opens at `~/.codex`. Click
   **Allow Access**. Usage loads.
4. Quit and relaunch Status: usage loads without another picker.
5. **Settings → Providers → Codex → Remove** returns the tab to Access required.

Reviewer steps — manual reauthentication:

1. With a granted but signed-out folder (e.g. run `codex logout`), the Codex tab
   shows **Not signed in** with the command `codex login --device-auth`.
2. Click **Copy & Open Terminal**: the command is on the clipboard and Terminal
   opens; nothing is typed or run.
3. Paste and run the command in Terminal, complete sign-in, then click
   **Re-check** in Status. Usage loads.

Release entitlement check (signed archive):

```sh
codesign -d --entitlements - --xml Status.app | plutil -p -
```

Expect `com.apple.security.app-sandbox`,
`com.apple.security.files.user-selected.read-write`, and
`com.apple.security.files.bookmarks.app-scope` (needed to persist the folder
grants as app-scoped bookmarks) set to true, and no
`com.apple.security.files.bookmarks.document-scope` or
`com.apple.security.temporary-exception.*` keys. The Info.plist must not contain
`NSAppleEventsUsageDescription`.

## Testing

Unit tests (`statusTests/`) cover the provider → resource mapping, paths
resolving beneath granted roots, missing/stale/replaced bookmarks, access
required vs. not signed in, and the exact (no trailing newline) copied login
command.

Manual checks use a signed, sandboxed **Release** build. For each folder-backed
provider:

1. Start with no bookmark → tab shows **Access required**.
2. Cancel the picker → app stays usable.
3. Pick the wrong folder → recovery message, nothing saved.
4. Pick the right folder → credential is found and usage loads.
5. Quit and relaunch → access persists with no picker.
6. Exercise token refresh / write-back where applicable.
7. Move or remove the folder → **Access needs to be granted again**.

For re-authentication: force a missing/expired login, confirm the displayed
command, **Copy** gives the exact command, **Copy & Open Terminal** activates
Terminal without typing anything, then sign in manually and **Re-check**.
