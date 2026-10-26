import Foundation
import Security

/// Reads the existing logins of Claude Code, Codex, Antigravity, and the GitHub CLIs
/// so the app can show real usage without asking for any API key. When a request
/// returns 401 the caller asks `forceRefresh` to exchange the refresh token.
///
/// Keychain items are read directly (the read prompts the user for access),
/// except Claude Code's, which is read through `/usr/bin/security` — see
/// `readKeychainItemViaSecurityTool` for why. CLI files are read only inside
/// folders the user granted through
/// `SecurityScopedAccess`; without a grant the lookup throws
/// `SecurityScopedAccessError` so the UI can ask for the folder rather than
/// report the provider as signed out. Providers with a Keychain login (Claude,
/// Copilot, Codex in `cli_auth_credentials_store = "keyring"` mode) try it
/// first and only fall back to — and only ask for — the folder when the
/// Keychain has nothing.
///
/// ── Verify on a real Mac ──
/// The OAuth client ids / token endpoints / stored JSON shapes below are
/// observed from the CLIs and may change between releases; they're isolated
/// here. On a refresh we write the rotated token back to the same store so the
/// CLI stays consistent (checking the store is writable first, and re-reading
/// it before exchanging in case the CLI already rotated the token itself).
///
/// Claude Code is the exception: its refresh token is single-use, so exchanging
/// it here races the CLI (logging it out), and writing the rotated token back
/// via SecItemUpdate resets the Keychain item's access grants — every
/// `security`-tool read the CLI makes starts prompting again. We never refresh
/// or write Claude's credentials; on 401 we just re-read what the CLI stored.
/// A Codex login stored in the Keychain gets the same treatment, for the same
/// reasons (Codex rotates its refresh token too).
enum LocalCredentials {
    // Observed public OAuth clients for the CLIs.
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    // Antigravity's installed-app OAuth client (shipped in every copy of the app,
    // so the "secret" isn't confidential), as used by openusage.
    private static let antigravityClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let antigravityClientSecret = "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"
    private static let googleTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let grokTokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    /// Owner of the user's folder grants. Replaced only by tests.
    static var access = SecurityScopedAccess.shared
    /// Environment variable provider (injectable for tests).
    static var environment: @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    /// Injectable so refresh/write-back tests never contact an OAuth server.
    static var refreshRequest: (URL, [String: String], Data) async throws -> HTTPResult = { url, headers, body in
        try await HTTPClient.send(url, method: "POST", headers: headers, body: body)
    }

    /// A generic-password Keychain item: its secret and the account it's filed
    /// under (the CLIs store the GitHub login there).
    struct KeychainItem: Equatable {
        var data: Data
        var account: String?
    }

    /// Reads one generic-password item by service (and optionally account).
    /// Replaced by tests so they never touch — or prompt for — the real Keychain.
    static var readKeychainItem: (_ service: String, _ account: String?) -> KeychainItem? = { service, account in
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data else { return nil }
        return KeychainItem(data: data, account: attributes[kSecAttrAccount as String] as? String)
    }

    /// Reads a generic-password item's secret through
    /// `security find-generic-password -s <service> -w`, the way the Claude
    /// Code CLI itself reads it. Nil when the tool fails or the item is missing.
    ///
    /// Why a subprocess: Claude Code rotates its token with
    /// `security add-generic-password -U`. Changing an item's data makes the
    /// Security framework re-create the item's storage group and reset its
    /// `partition_id` ACL to the writer's partition (`apple-tool:`), while the
    /// trusted-application list is preserved. So after every rotation this app
    /// is still a trusted application but its `teamid:` partition is gone, and
    /// a direct `SecItemCopyMatching` prompts for the keychain password again
    /// no matter how often the user chose "Always Allow". `/usr/bin/security`
    /// is the item's creator and always in its partition list, so a read
    /// through it never prompts. Verified from inside the App Sandbox.
    ///
    /// Replaced by tests so they never spawn the tool against the real Keychain.
    static var readKeychainItemViaSecurityTool: (_ service: String) -> Data? = { service in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Drain before waiting so a large secret can't fill the pipe and deadlock.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8) else { return nil }
        // `-w` appends a newline; the stored JSON has none.
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }

    // MARK: Public API

    /// The current credential as stored, without any network refresh. Refresh is
    /// driven reactively by `forceRefresh` after a request returns 401.
    ///
    /// `async` (and not actor-isolated) so the Keychain/file reads run off the
    /// main thread when called from the `@MainActor` store.
    ///
    /// Returns nil when the CLI has no login; throws `SecurityScopedAccessError`
    /// when Status can't look because the folder isn't (or is no longer) granted.
    static func credential(for provider: Provider) async throws -> Credential? {
        guard let loaded = try load(provider) else { return nil }
        if let key = loaded.apiKey { return .apiKey(key) }
        return .oauth(accessToken: loaded.access, accountID: loaded.accountID, displayName: loaded.displayName)
    }

    /// Drops any in-memory cached credentials for the provider so subsequent reads hit the disk/keychain fresh.
    static func resetCache(for provider: Provider) {
        keychainLock.withLock {
            switch provider {
            case .claude:
                cachedClaudeKeychain = nil
            case .codex:
                cachedCodexKeychain = nil
            case .antigravity:
                cachedAntigravityKeychain = nil
                refreshedAntigravity = nil
            case .copilot:
                cachedCopilotKeychain = nil
            default:
                break
            }
        }
    }

    /// Exchanges the refresh token for a new access token and writes it back to
    /// the CLI's store. Returns nil when there's no refresh token to use.
    ///
    /// Tries the cached Keychain copy first: the fresh Keychain read is what
    /// can raise a permission dialog, so it's reserved for the case where the
    /// cached refresh token no longer works rather than paid on every expired
    /// access token.
    ///
    /// Claude is never refreshed here — its refresh token is single-use and
    /// owned by the CLI (see the type doc). Codex and Grok re-read their store
    /// first for the same reason: the CLI may have already rotated the
    /// token, and exchanging a refresh token it still holds would race it.
    /// A Codex login held in the Keychain is, like Claude's, only ever re-read.
    ///
    /// `failed` is the credential that just 401'd, so a re-read can tell a
    /// rotated token apart from the same stale one.
    static func forceRefresh(_ provider: Provider, after failed: Credential? = nil) async -> Credential? {
        let failedAccess = oauthAccessToken(failed)
        switch provider {
        case .claude:
            return rereadClaude(failedAccess: failedAccess)
        case .codex, .grok:
            // Re-read the store (dropping any cached Keychain copy) and look
            // for a CLI-rotated token before spending our own refresh exchange.
            if provider == .codex { keychainLock.withLock { cachedCodexKeychain = nil } }
            let loaded = try? load(provider)
            if let loaded, loaded.apiKey == nil, !loaded.access.isEmpty, loaded.access != failedAccess {
                return .oauth(accessToken: loaded.access, accountID: loaded.accountID, displayName: loaded.displayName)
            }
            // Never exchange a Keychain-stored Codex refresh token: it's
            // single-use and we can't write the rotation back into the CLI's
            // item without disturbing its access grants.
            if loaded?.source == .codexKeychain { return nil }
            return await refreshFromStore(provider)
        case .antigravity:
            // Google refresh tokens are reusable, so exchanging is safe; try
            // the cached Keychain copy first because the fresh read is what
            // can raise a permission dialog.
            if let credential = await refreshFromStore(provider) { return credential }
            let hadCache = keychainLock.withLock {
                let had = cachedAntigravityKeychain != nil
                cachedAntigravityKeychain = nil
                refreshedAntigravity = nil
                return had
            }
            // Without a cache the attempt above already read the store fresh.
            guard hadCache else { return nil }
            return await refreshFromStore(provider)
        case .copilot:
            // No refresh token to exchange, but `copilot login` / `gh auth
            // login` rotate the Keychain item in place — re-read it and only
            // retry if the stored token differs from the one that just 401'd.
            keychainLock.withLock { cachedCopilotKeychain = nil }
            guard let loaded = try? loadCopilot(), !loaded.access.isEmpty,
                  loaded.access != failedAccess else { return nil }
            return .oauth(accessToken: loaded.access, accountID: loaded.accountID, displayName: loaded.displayName)
        }
    }

    private static func oauthAccessToken(_ credential: Credential?) -> String? {
        if case let .oauth(accessToken, _, _) = credential { return accessToken }
        return nil
    }

    /// Drops the cached Claude Keychain copy and reads the store again. Returns
    /// nil when the store still holds the access token that just 401'd — no
    /// point retrying it; the caller surfaces re-auth instead.
    private static func rereadClaude(failedAccess: String?) -> Credential? {
        let cachedAccess = keychainLock.withLock { () -> String? in
            defer { cachedClaudeKeychain = nil }
            return cachedClaudeKeychain.flatMap { parseClaude($0, source: .claudeKeychain)?.access }
        }
        let stale = failedAccess ?? cachedAccess
        guard let loaded = try? loadClaude(), !loaded.access.isEmpty, loaded.access != stale else { return nil }
        return .oauth(accessToken: loaded.access, accountID: loaded.accountID, displayName: loaded.displayName)
    }

    private static func refreshFromStore(_ provider: Provider) async -> Credential? {
        guard let loaded = try? load(provider), loaded.refresh != nil,
              let refreshed = try? await refresh(loaded),
              // An exchange that produced no new token isn't worth retrying.
              refreshed.access != loaded.access else { return nil }
        return .oauth(accessToken: refreshed.access, accountID: refreshed.accountID, displayName: refreshed.displayName)
    }

    // MARK: Loaded credential

    private enum Source {
        case claudeKeychain, claudeFile, codexKeychain, codexFile, antigravityKeychain, copilotKeychain, copilotConfig, grokFile
    }

    private struct Loaded {
        var access: String
        var refresh: String?
        var accountID: String?
        /// User-facing label shown in the tab header.
        var displayName: String?
        var source: Source
        /// Set when the CLI is configured with a plain API key rather than OAuth.
        var apiKey: String?
        /// Full original JSON, preserved so write-back only touches token fields.
        var raw: [String: Any]
    }

    private static func load(_ provider: Provider) throws -> Loaded? {
        switch provider {
        case .claude: return try loadClaude()
        case .codex: return try loadCodex()
        case .antigravity: return loadAntigravity()
        case .copilot: return try loadCopilot()
        case .grok: return try loadGrok()
        }
    }

    // MARK: Claude Code

    /// The Keychain item is the usual store; the `.claude` folder is only
    /// needed (and only requested) when it's missing.
    private static func loadClaude() throws -> Loaded? {
        if let raw = claudeKeychainJSON(), let loaded = parseClaude(raw, source: .claudeKeychain) {
            return loaded
        }
        var accessError: Error?
        let raw: [String: Any]?
        do {
            raw = try readJSONObject(".credentials.json", in: .claudeData)
        } catch {
            raw = nil
            accessError = error
        }
        if let raw, let loaded = parseClaude(raw, source: .claudeFile) {
            return loaded
        }
        let env = environment()
        for name in ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"] {
            if let value = env[name], !value.isEmpty {
                return Loaded(access: "", refresh: nil, accountID: nil, displayName: "Anthropic API",
                              source: .claudeFile, apiKey: value, raw: [:])
            }
        }
        if let accessError { throw accessError }
        return nil
    }

    private static func parseClaude(_ raw: [String: Any], source: Source) -> Loaded? {
        let root = JSON(raw)
        let oauth = root["claudeAiOauth"]
        guard let access = oauth["accessToken"].string ?? root["accessToken"].string,
              !access.isEmpty else { return nil }
        // Claude Code creds don't carry an email — surface the subscription
        // tier instead (e.g. "Claude Max", "Claude Team").
        let display = oauth["subscriptionType"].string.map { "Claude \($0.capitalized)" }
        return Loaded(access: access, refresh: oauth["refreshToken"].string,
                      accountID: nil, displayName: display,
                      source: source, apiKey: nil, raw: raw)
    }

    /// Serializes Keychain reads/writes so concurrent refreshes can't stack
    /// permission prompts, and caches the decoded JSON so subsequent syncs
    /// read from memory. Each fresh direct read can prompt (and even a granted
    /// item prompts again once the CLI has rotated it — see
    /// `readKeychainItemViaSecurityTool`), so reads are kept to launch and
    /// refresh-token failure.
    private static let keychainLock = NSLock()
    private static var cachedClaudeKeychain: [String: Any]?
    private static var cachedCodexKeychain: [String: Any]?
    private static var cachedAntigravityKeychain: [String: Any]?
    private static var cachedCopilotKeychain: (token: String, login: String?)?

    private static let claudeKeychainService = "Claude Code-credentials"

    /// Reads through the `security` tool first (never prompts — see
    /// `readKeychainItemViaSecurityTool`); the direct Keychain read is only a
    /// fallback for when the tool can't be run.
    private static func claudeKeychainJSON() -> [String: Any]? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let cached = cachedClaudeKeychain { return cached }
        guard let data = readKeychainItemViaSecurityTool(claudeKeychainService)
                ?? keychainData(service: claudeKeychainService) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        cachedClaudeKeychain = json
        return json
    }

    private static func keychainData(service: String, account: String? = nil) -> Data? {
        readKeychainItem(service, account)?.data
    }

    /// The item's secret as text. Go's `keyring` package (used by gh and
    /// Antigravity) wraps values it can't store verbatim as
    /// `go-keyring-base64:<base64>`; that wrapper is unwrapped here.
    private static func keychainString(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))),
                  let string = String(data: decoded, encoding: .utf8) else { return nil }
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: Codex CLI

    /// Codex keeps the same auth JSON either in `~/.codex/auth.json` or — with
    /// `cli_auth_credentials_store = "keyring"` — in a Keychain item (service
    /// `Codex Auth`, account `cli|<hash of CODEX_HOME>`). Both can exist at
    /// once after a mode switch, so when they disagree the store the CLI wrote
    /// to most recently (`last_refresh`) wins. The folder is only required —
    /// and only asked for — when the Keychain holds no login.
    private static func loadCodex() throws -> Loaded? {
        let fromKeychain = codexKeychainJSON().flatMap { parseCodex($0, source: .codexKeychain) }
        var accessError: Error?
        let fromFile: Loaded?
        do {
            fromFile = try readJSONObject("auth.json", in: .codexData).flatMap { parseCodex($0, source: .codexFile) }
        } catch {
            fromFile = nil
            accessError = error
        }
        switch (fromKeychain, fromFile) {
        case let (keychain?, file?):
            return codexLastRefresh(file) > codexLastRefresh(keychain) ? file : keychain
        case let (keychain?, nil):
            return keychain
        case let (nil, file?):
            return file
        case (nil, nil):
            break
        }
        let env = environment()
        if let envKey = env["OPENAI_API_KEY"], !envKey.isEmpty {
            return Loaded(access: "", refresh: nil, accountID: nil, displayName: "OpenAI API",
                          source: .codexFile, apiKey: envKey, raw: [:])
        }
        if let accessError { throw accessError }
        return nil
    }

    private static func parseCodex(_ raw: [String: Any], source: Source) -> Loaded? {
        let root = JSON(raw)
        if let access = root["tokens"]["access_token"].string, !access.isEmpty {
            // Codex needs the opaque `account_id` UUID at request time (sent
            // as the `chatgpt-account-id` header), but we display the ChatGPT
            // account email parsed from `id_token`.
            let email = root["tokens"]["id_token"].string.flatMap(emailFromIDToken(_:))
            return Loaded(access: access, refresh: root["tokens"]["refresh_token"].string,
                          accountID: root["tokens"]["account_id"].string,
                          displayName: email,
                          source: source, apiKey: nil, raw: raw)
        }
        if let key = root["OPENAI_API_KEY"].string, !key.isEmpty {
            return Loaded(access: "", refresh: nil, accountID: nil, displayName: nil,
                          source: source, apiKey: key, raw: raw)
        }
        return nil
    }

    /// `last_refresh` as a date; the file writes whole seconds, the Keychain
    /// copy fractional ones. Missing/unparseable sorts oldest.
    private static func codexLastRefresh(_ loaded: Loaded) -> Date {
        guard let raw = loaded.raw["last_refresh"] as? String else { return .distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? .distantPast
    }

    private static func codexKeychainJSON() -> [String: Any]? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let cached = cachedCodexKeychain { return cached }
        // The account hash depends on the install's CODEX_HOME, so match on
        // the service alone and only insist on the CLI's `cli|` prefix.
        guard let item = readKeychainItem("Codex Auth", nil),
              item.account?.hasPrefix("cli|") ?? true,
              let text = keychainString(item.data) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        cachedCodexKeychain = json
        return json
    }

    // MARK: Antigravity

    /// The Antigravity app / `agy` CLI keep their Google OAuth login in the
    /// Keychain (service `gemini`, account `antigravity`) as an optional
    /// `go-keyring-base64:` wrapper around `{ token: { access_token,
    /// refresh_token, expiry } }`. We never write back to that item: a
    /// refreshed access token lives only in `refreshedAntigravity`.
    private static var refreshedAntigravity: (refresh: String, access: String, expiry: Date)?

    private static func loadAntigravity() -> Loaded? {
        guard let raw = antigravityKeychainJSON() else { return nil }
        let root = JSON(raw)
        let token = root["token"].value == nil ? root : root["token"]
        let refresh = token["refresh_token"].string ?? token["refreshToken"].string
        var access = token["access_token"].string ?? token["accessToken"].string
        let refreshed = keychainLock.withLock { refreshedAntigravity }
        if let refreshed, refreshed.refresh == refresh, refreshed.expiry > Date() {
            access = refreshed.access
        }
        let email = (root["id_token"].string ?? token["id_token"].string).flatMap(emailFromIDToken(_:))
        guard let access, !access.isEmpty else {
            // No access token but a refresh token: let the 401 path refresh it.
            guard refresh != nil else { return nil }
            return Loaded(access: "", refresh: refresh, accountID: nil, displayName: email,
                          source: .antigravityKeychain, apiKey: nil, raw: raw)
        }
        return Loaded(access: access, refresh: refresh, accountID: nil, displayName: email,
                      source: .antigravityKeychain, apiKey: nil, raw: raw)
    }

    private static func antigravityKeychainJSON() -> [String: Any]? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let cached = cachedAntigravityKeychain { return cached }
        guard let data = keychainData(service: "gemini", account: "antigravity"),
              let text = keychainString(data) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        cachedAntigravityKeychain = json
        return json
    }

    /// Decodes an OAuth `id_token` JWT and returns the `email` claim if present.
    /// Used to surface the signed-in account in the UI.
    private static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["email"] as? String
    }

    // MARK: Grok CLI (xAI)

    /// xAI's Grok CLI stores an OIDC login in `~/.grok/auth.json` keyed by
    /// `<issuer>::<client_id>`. Each entry carries the access JWT (`key`), a
    /// refresh token, and the signed-in email/team. We also accept a plain
    /// `XAI_API_KEY` / `GROK_API_KEY` env var so non-CLI users can sign in;
    /// only without one does a missing folder grant surface as an error.
    private static func loadGrok() throws -> Loaded? {
        var accessError: Error?
        let raw: [String: Any]?
        do {
            raw = try readJSONObject("auth.json", in: .grokData)
        } catch {
            raw = nil
            accessError = error
        }
        if let raw, let (_, entry) = grokOIDCEntry(in: raw) {
            let json = JSON(entry)
            if let access = json["key"].string, !access.isEmpty {
                return Loaded(
                    access: access,
                    refresh: json["refresh_token"].string,
                    accountID: json["team_id"].string,
                    displayName: json["email"].string,
                    source: .grokFile, apiKey: nil, raw: raw
                )
            }
        }
        let env = environment()
        for name in ["XAI_API_KEY", "GROK_API_KEY"] {
            if let value = env[name], !value.isEmpty {
                return Loaded(access: "", refresh: nil, accountID: nil, displayName: "xAI API",
                              source: .grokFile, apiKey: value, raw: [:])
            }
        }
        if let accessError { throw accessError }
        return nil
    }

    /// First entry in `auth.json` that looks like a Grok OIDC login (key
    /// namespaced under `auth.x.ai`).
    private static func grokOIDCEntry(in raw: [String: Any]) -> (String, [String: Any])? {
        for key in raw.keys.sorted() where key.contains("auth.x.ai") {
            if let entry = raw[key] as? [String: Any] { return (key, entry) }
        }
        return nil
    }

    // MARK: GitHub CLI / Copilot

    /// The Keychain is the usual store, so no folder grant is needed: the
    /// Copilot CLI (`copilot login`) files a bare GitHub token under service
    /// `copilot-cli`, account `https://github.com:<login>`; the gh CLI
    /// (`gh auth login`) under service `gh:github.com`, account `<login>`,
    /// go-keyring-wrapped. Only when neither exists is the granted folder
    /// read — `~/.config/github-copilot` (the Copilot plugin's JSON config) or
    /// `~/.config/gh` (`hosts.yml`, which only carries the token for logins
    /// made with `--insecure-storage`) — never all of `~/.config`.
    private static func loadCopilot() throws -> Loaded? {
        if let (token, login) = copilotKeychainToken() {
            return Loaded(access: token, refresh: nil,
                          accountID: login, displayName: login,
                          source: .copilotKeychain, apiKey: nil, raw: [:])
        }
        for name in ["apps.json", "hosts.json"] {
            if let raw = try readJSONObject(name, in: .githubConfig) {
                for (key, value) in raw where key.contains("github.com") {
                    let entry = JSON(value)
                    if let token = entry["oauth_token"].string, !token.isEmpty {
                        let user = entry["user"].string
                        return Loaded(access: token, refresh: nil,
                                      accountID: user, displayName: user,
                                      source: .copilotConfig, apiKey: nil, raw: [:])
                    }
                }
            }
        }
        if let (token, user) = try ghHostsToken() {
            return Loaded(access: token, refresh: nil,
                          accountID: user, displayName: user,
                          source: .copilotConfig, apiKey: nil, raw: [:])
        }
        return nil
    }

    /// First GitHub token found in the Keychain (Copilot CLI, then gh), with
    /// the login it was filed under. Cached like the other Keychain reads so a
    /// sync doesn't re-prompt; `resetCache` / `forceRefresh` drop the cache.
    private static func copilotKeychainToken() -> (token: String, login: String?)? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let cached = cachedCopilotKeychain { return cached }
        let services = [
            ("copilot-cli", { (account: String?) -> String? in
                // `https://github.com:<login>` → `<login>`.
                account.flatMap { $0.split(separator: ":").last.map(String.init) }
            }),
            ("gh:github.com", { (account: String?) -> String? in account }),
        ]
        for (service, login) in services {
            guard let item = readKeychainItem(service, nil),
                  let token = keychainString(item.data), !token.isEmpty else { continue }
            let found = (token: token, login: login(item.account).flatMap { $0.isEmpty ? nil : $0 })
            cachedCopilotKeychain = found
            return found
        }
        return nil
    }

    /// Minimal parse of `~/.config/gh/hosts.yml` for github.com's oauth_token/user.
    private static func ghHostsToken() throws -> (String, String?)? {
        guard let data = try readData("hosts.yml", in: .githubConfig),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var inGitHub = false
        var token: String?
        var user: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !line.hasPrefix(" ") && line.contains(":") {
                inGitHub = line.hasPrefix("github.com:")
                continue
            }
            guard inGitHub else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oauth_token:") {
                token = trimmed.dropFirst("oauth_token:".count).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("user:") {
                user = trimmed.dropFirst("user:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let token, !token.isEmpty else { return nil }
        return (token, user)
    }

    // MARK: Refresh

    private static func refresh(_ loaded: Loaded) async throws -> Loaded {
        guard let refreshToken = loaded.refresh else { return loaded }
        // Exchanging may rotate (and invalidate) the refresh token, so never
        // start one we can't write back — that would strand the CLI with a
        // dead token and log it out.
        if let (resource, name) = authFile(loaded.source) {
            let writable = try access.withAccess(to: resource) { root in
                // Atomic replacement also requires creating a sibling file.
                FileManager.default.isWritableFile(atPath: root.path)
                    && (SecurityScopedAccess.file(name, in: root).map { FileManager.default.isWritableFile(atPath: $0.path) } ?? false)
            }
            guard writable else { throw CocoaError(.fileWriteNoPermission) }
        }
        switch loaded.source {
        case .claudeKeychain, .claudeFile, .codexKeychain:
            // Never exchanged: the CLI owns these single-use refresh tokens
            // and we don't write into its Keychain items.
            return loaded
        case .codexFile:
            return try await refreshCodex(loaded, refreshToken: refreshToken)
        case .antigravityKeychain:
            return try await refreshAntigravity(loaded, refreshToken: refreshToken)
        case .grokFile:
            return try await refreshGrok(loaded, refreshToken: refreshToken)
        case .copilotKeychain, .copilotConfig:
            return loaded
        }
    }

    private static func refreshCodex(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": codexClientID,
        ])
        let result = try await refreshRequest(codexTokenURL, ["Content-Type": "application/json"], body)
        guard let access = result.json["access_token"].string, !access.isEmpty else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        var tokens = (updated.raw["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = updated.access
        if let idToken = result.json["id_token"].string { tokens["id_token"] = idToken }
        if let refresh = updated.refresh { tokens["refresh_token"] = refresh }
        updated.raw["tokens"] = tokens
        updated.raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        return try persist(updated, after: loaded)
    }

    private static func refreshGrok(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        guard let (entryKey, entry) = grokOIDCEntry(in: loaded.raw) else { return loaded }
        // `oidc_client_id` is stored alongside; fall back to the suffix of the
        // entry key (`<issuer>::<client_id>`) if it's somehow missing.
        let clientID = JSON(entry)["oidc_client_id"].string
            ?? String(entryKey.split(separator: ":").last ?? "")
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let result = try await refreshRequest(grokTokenURL,
            ["Content-Type": "application/x-www-form-urlencoded"], Data(form.utf8))
        guard let access = result.json["access_token"].string, !access.isEmpty else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        var newEntry = entry
        newEntry["key"] = access
        if let refresh = updated.refresh { newEntry["refresh_token"] = refresh }
        if let expiresIn = result.json["expires_in"].double {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            newEntry["expires_at"] = formatter.string(from: Date().addingTimeInterval(expiresIn))
        }
        updated.raw[entryKey] = newEntry
        return try persist(updated, after: loaded)
    }

    private static func refreshAntigravity(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let form = [
            "client_id": antigravityClientID,
            "client_secret": antigravityClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let result = try await refreshRequest(googleTokenURL,
            ["Content-Type": "application/x-www-form-urlencoded"], Data(form.utf8))
        guard let access = result.json["access_token"].string, !access.isEmpty else { return loaded }

        var updated = loaded
        updated.access = access
        // Keep a minute of headroom so a near-expiry token isn't reused.
        let expiry = Date().addingTimeInterval((result.json["expires_in"].double ?? 3_600) - 60)
        keychainLock.withLock { refreshedAntigravity = (refreshToken, access, expiry) }
        return updated
    }

    // MARK: Write-back

    /// Never report a successful rotation unless it reached the CLI's store.
    private static func persist(_ updated: Loaded, after original: Loaded) throws -> Loaded {
        guard let (resource, name) = authFile(updated.source) else { throw CocoaError(.fileWriteUnknown) }
        return try access.withAccess(to: resource) { root in
            guard let file = SecurityScopedAccess.file(name, in: root) else { throw CocoaError(.fileWriteInvalidFileName) }
            let currentData = try Data(contentsOf: file)
            guard let raw = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let current: Loaded?
            switch updated.source {
            case .codexFile: current = parseCodex(raw, source: .codexFile)
            case .grokFile:
                if let (_, entry) = grokOIDCEntry(in: raw), let token = entry["key"] as? String {
                    var loaded = original
                    loaded.raw = raw
                    loaded.access = token
                    loaded.refresh = entry["refresh_token"] as? String
                    current = loaded
                } else { current = nil }
            default: current = nil
            }
            guard var current, current.apiKey == nil, !current.access.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // The CLI may have signed in or rotated while our exchange was
            // awaiting the network. Its newer credentials win; never replace
            // them with the result of an exchange for the old login.
            guard current.access == original.access, current.refresh == original.refresh else { return current }
            var merged = raw
            switch updated.source {
            case .codexFile:
                var tokens = raw["tokens"] as? [String: Any] ?? [:]
                let newTokens = updated.raw["tokens"] as? [String: Any] ?? [:]
                for key in ["access_token", "refresh_token", "id_token"] {
                    if let value = newTokens[key] { tokens[key] = value }
                }
                merged["tokens"] = tokens
                merged["last_refresh"] = updated.raw["last_refresh"]
            case .grokFile:
                guard let (key, entry) = grokOIDCEntry(in: raw),
                      let newEntry = updated.raw[key] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                var mergedEntry = entry
                for field in ["key", "refresh_token", "expires_at"] {
                    if let value = newEntry[field] { mergedEntry[field] = value }
                }
                merged[key] = mergedEntry
            default: throw CocoaError(.fileWriteUnknown)
            }
            let data = try JSONSerialization.data(withJSONObject: merged, options: .prettyPrinted)
            try data.write(to: file, options: .atomic)
            current.access = updated.access
            current.refresh = updated.refresh
            current.raw = merged
            return current
        }
    }

    /// The CLI auth file a refreshed token is written back to; nil for sources
    /// that are never written (Claude, Antigravity, Copilot, Keychain Codex).
    private static func authFile(_ source: Source) -> (ExternalResource, String)? {
        switch source {
        case .codexFile: return (.codexData, "auth.json")
        case .grokFile: return (.grokData, "auth.json")
        case .claudeKeychain, .claudeFile, .codexKeychain, .antigravityKeychain, .copilotKeychain, .copilotConfig:
            return nil
        }
    }

    // MARK: Helpers

    /// Reads `name` inside the granted folder. Nil when the file is missing or
    /// unreadable; throws only when the folder itself isn't accessible.
    private static func readData(_ name: String, in resource: ExternalResource) throws -> Data? {
        try access.withAccess(to: resource) { root in
            SecurityScopedAccess.file(name, in: root).flatMap { try? Data(contentsOf: $0) }
        }
    }

    private static func readJSONObject(_ name: String, in resource: ExternalResource) throws -> [String: Any]? {
        guard let data = try readData(name, in: resource) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension CharacterSet {
    /// Allowed characters for a single x-www-form-urlencoded value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
