import Foundation
import Security

/// Reads the existing logins of Claude Code, Codex, Antigravity, and the GitHub CLIs
/// so the app can show real usage without asking for any API key. When a request
/// returns 401 the caller asks `forceRefresh` to exchange the refresh token.
///
/// Reading these locations (another app's Keychain item, files under the home
/// directory) relies on the sandbox temporary-exception entitlements in
/// status.entitlements; the Keychain read prompts the user for access.
///
/// ── Verify on a real Mac ──
/// The OAuth client ids / token endpoints / stored JSON shapes below are
/// observed from the CLIs and may change between releases; they're isolated
/// here. On a refresh we write the rotated token back to the same store so the
/// CLI stays consistent, and fall back to the existing token on failure.
enum LocalCredentials {
    // Observed public OAuth clients for the CLIs.
    private static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let claudeTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    // Antigravity's installed-app OAuth client (shipped in every copy of the app,
    // so the "secret" isn't confidential), as used by openusage.
    private static let antigravityClientID = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private static let antigravityClientSecret = "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"
    private static let googleTokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let grokTokenURL = URL(string: "https://auth.x.ai/oauth2/token")!

    private static var home: URL { FileManager.default.realHomeDirectoryForCurrentUser }

    // MARK: Public API

    /// The current credential as stored, without any network refresh. Refresh is
    /// driven reactively by `forceRefresh` after a request returns 401.
    ///
    /// `async` (and not actor-isolated) so the Keychain/file reads run off the
    /// main thread when called from the `@MainActor` store.
    static func credential(for provider: Provider) async -> Credential? {
        guard let loaded = load(provider) else { return nil }
        if let key = loaded.apiKey { return .apiKey(key) }
        return .oauth(accessToken: loaded.access, accountID: loaded.accountID, displayName: loaded.displayName)
    }

    /// Drops any in-memory cached credentials for the provider so subsequent reads hit the disk/keychain fresh.
    static func resetCache(for provider: Provider) {
        keychainLock.withLock {
            switch provider {
            case .claude:
                cachedClaudeKeychain = nil
            case .antigravity:
                cachedAntigravityKeychain = nil
                refreshedAntigravity = nil
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
    /// cached refresh token no longer works (e.g. the Claude Code CLI rotated
    /// it out-of-band) rather than paid on every expired access token.
    static func forceRefresh(_ provider: Provider) async -> Credential? {
        if let credential = await refreshFromStore(provider) { return credential }
        guard provider == .claude || provider == .antigravity else { return nil }
        let hadCache = keychainLock.withLock {
            let had = provider == .claude ? cachedClaudeKeychain != nil : cachedAntigravityKeychain != nil
            if provider == .claude {
                cachedClaudeKeychain = nil
            } else {
                cachedAntigravityKeychain = nil
                refreshedAntigravity = nil
            }
            return had
        }
        // Without a cache the attempt above already read the store fresh.
        guard hadCache else { return nil }
        return await refreshFromStore(provider)
    }

    private static func refreshFromStore(_ provider: Provider) async -> Credential? {
        guard let loaded = load(provider), loaded.refresh != nil,
              let refreshed = try? await refresh(loaded) else { return nil }
        return .oauth(accessToken: refreshed.access, accountID: refreshed.accountID, displayName: refreshed.displayName)
    }

    // MARK: Loaded credential

    private enum Source { case claudeKeychain, claudeFile, codexFile, antigravityKeychain, copilotConfig, grokFile }

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

    private static func load(_ provider: Provider) -> Loaded? {
        switch provider {
        case .claude: return loadClaude()
        case .codex: return loadCodex()
        case .antigravity: return loadAntigravity()
        case .copilot: return loadCopilot()
        case .grok: return loadGrok()
        }
    }

    // MARK: Claude Code

    private static func loadClaude() -> Loaded? {
        if let raw = claudeKeychainJSON(), let loaded = parseClaude(raw, source: .claudeKeychain) {
            return loaded
        }
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let raw = readJSONObject(file), let loaded = parseClaude(raw, source: .claudeFile) {
            return loaded
        }
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
    /// read from memory. Each fresh read can prompt when the process fails
    /// dynamic code-signature validation (e.g. running under the debugger),
    /// so reads are kept to launch and refresh-token failure.
    private static let keychainLock = NSLock()
    private static var cachedClaudeKeychain: [String: Any]?
    private static var cachedAntigravityKeychain: [String: Any]?

    private static func claudeKeychainJSON() -> [String: Any]? {
        keychainLock.lock()
        defer { keychainLock.unlock() }
        if let cached = cachedClaudeKeychain { return cached }
        guard let data = keychainData(service: "Claude Code-credentials") else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        cachedClaudeKeychain = json
        return json
    }

    private static func keychainData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: Codex CLI

    private static func loadCodex() -> Loaded? {
        let file = home.appendingPathComponent(".codex/auth.json")
        guard let raw = readJSONObject(file) else { return nil }
        let root = JSON(raw)
        if let access = root["tokens"]["access_token"].string, !access.isEmpty {
            // Codex needs the opaque `account_id` UUID at request time (sent
            // as the `chatgpt-account-id` header), but we display the ChatGPT
            // account email parsed from `id_token`.
            let email = root["tokens"]["id_token"].string.flatMap(emailFromIDToken(_:))
            return Loaded(access: access, refresh: root["tokens"]["refresh_token"].string,
                          accountID: root["tokens"]["account_id"].string,
                          displayName: email,
                          source: .codexFile, apiKey: nil, raw: raw)
        }
        if let key = root["OPENAI_API_KEY"].string, !key.isEmpty {
            return Loaded(access: "", refresh: nil, accountID: nil, displayName: nil,
                          source: .codexFile, apiKey: key, raw: raw)
        }
        return nil
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
              var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let prefix = "go-keyring-base64:"
        if text.hasPrefix(prefix) {
            guard let decoded = Data(base64Encoded: String(text.dropFirst(prefix.count))),
                  let string = String(data: decoded, encoding: .utf8) else { return nil }
            text = string
        }
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
    /// `XAI_API_KEY` / `GROK_API_KEY` env var so non-CLI users can sign in.
    private static func loadGrok() -> Loaded? {
        let file = home.appendingPathComponent(".grok/auth.json")
        if let raw = readJSONObject(file), let (_, entry) = grokOIDCEntry(in: raw) {
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
        let env = ProcessInfo.processInfo.environment
        for name in ["XAI_API_KEY", "GROK_API_KEY"] {
            if let value = env[name], !value.isEmpty {
                return Loaded(access: "", refresh: nil, accountID: nil, displayName: nil,
                              source: .grokFile, apiKey: value, raw: [:])
            }
        }
        return nil
    }

    /// First entry in `auth.json` that looks like a Grok OIDC login (key
    /// namespaced under `auth.x.ai`).
    private static func grokOIDCEntry(in raw: [String: Any]) -> (String, [String: Any])? {
        for (key, value) in raw where key.contains("auth.x.ai") {
            if let entry = value as? [String: Any] { return (key, entry) }
        }
        return nil
    }

    // MARK: GitHub CLI / Copilot

    private static func loadCopilot() -> Loaded? {
        // Prefer the Copilot plugin config (JSON), then the gh CLI hosts file.
        for name in ["github-copilot/apps.json", "github-copilot/hosts.json"] {
            let file = configHome.appendingPathComponent(name)
            if let raw = readJSONObject(file) {
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
        if let (token, user) = ghHostsToken() {
            return Loaded(access: token, refresh: nil,
                          accountID: user, displayName: user,
                          source: .copilotConfig, apiKey: nil, raw: [:])
        }
        return nil
    }

    /// Minimal parse of `~/.config/gh/hosts.yml` for github.com's oauth_token/user.
    private static func ghHostsToken() -> (String, String?)? {
        let file = configHome.appendingPathComponent("gh/hosts.yml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
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

    private static var configHome: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg)
        }
        return home.appendingPathComponent(".config")
    }

    // MARK: Refresh

    private static func refresh(_ loaded: Loaded) async throws -> Loaded {
        guard let refreshToken = loaded.refresh else { return loaded }
        switch loaded.source {
        case .claudeKeychain, .claudeFile:
            return try await refreshClaude(loaded, refreshToken: refreshToken)
        case .codexFile:
            return try await refreshCodex(loaded, refreshToken: refreshToken)
        case .antigravityKeychain:
            return try await refreshAntigravity(loaded, refreshToken: refreshToken)
        case .grokFile:
            return try await refreshGrok(loaded, refreshToken: refreshToken)
        case .copilotConfig:
            return loaded
        }
    }

    private static func refreshClaude(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": claudeClientID,
        ])
        let result = try await HTTPClient.send(claudeTokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body)
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        var oauth = (updated.raw["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = updated.access
        if let refresh = updated.refresh { oauth["refreshToken"] = refresh }
        if let expiresIn = result.json["expires_in"].double {
            oauth["expiresAt"] = Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
        }
        updated.raw["claudeAiOauth"] = oauth
        persist(updated.raw, to: updated.source)
        return updated
    }

    private static func refreshCodex(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": codexClientID,
        ])
        let result = try await HTTPClient.send(codexTokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body)
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        var tokens = (updated.raw["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = updated.access
        if let idToken = result.json["id_token"].string { tokens["id_token"] = idToken }
        if let refresh = updated.refresh { tokens["refresh_token"] = refresh }
        updated.raw["tokens"] = tokens
        updated.raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        persist(updated.raw, to: updated.source)
        return updated
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
        let result = try await HTTPClient.send(grokTokenURL, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8))
        guard let access = result.json["access_token"].string else { return loaded }

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
        persist(updated.raw, to: updated.source)
        return updated
    }

    private static func refreshAntigravity(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let form = [
            "client_id": antigravityClientID,
            "client_secret": antigravityClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let result = try await HTTPClient.send(googleTokenURL, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8))
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        // Keep a minute of headroom so a near-expiry token isn't reused.
        let expiry = Date().addingTimeInterval((result.json["expires_in"].double ?? 3_600) - 60)
        keychainLock.withLock { refreshedAntigravity = (refreshToken, access, expiry) }
        return updated
    }

    // MARK: Write-back

    private static func persist(_ raw: [String: Any], to source: Source) {
        let pretty = source == .codexFile || source == .grokFile
        guard let data = try? JSONSerialization.data(
            withJSONObject: raw,
            options: pretty ? .prettyPrinted : []
        ) else { return }
        switch source {
        case .claudeKeychain:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
            ]
            keychainLock.lock()
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            cachedClaudeKeychain = raw
            keychainLock.unlock()
        case .claudeFile:
            try? data.write(to: home.appendingPathComponent(".claude/.credentials.json"), options: .atomic)
        case .codexFile:
            try? data.write(to: home.appendingPathComponent(".codex/auth.json"), options: .atomic)
        case .grokFile:
            try? data.write(to: home.appendingPathComponent(".grok/auth.json"), options: .atomic)
        case .antigravityKeychain, .copilotConfig:
            break
        }
    }

    // MARK: Helpers

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension FileManager {
    /// The user's real home directory. In a sandboxed app,
    /// `homeDirectoryForCurrentUser` points at the app *container*
    /// (~/Library/Containers/…/Data), but the CLI credential and config files
    /// live in the real home — which the temporary-exception entitlements
    /// grant access to.
    var realHomeDirectoryForCurrentUser: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return homeDirectoryForCurrentUser
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
