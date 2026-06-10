import Foundation
import Security

/// Reads the existing logins of the Claude Code, Codex, Gemini, and GitHub CLIs
/// so the app can show real usage without asking for any API key. When a request
/// returns 401 the caller asks `forceRefresh` to exchange the refresh token.
///
/// Reading these locations (another app's Keychain item, files under the home
/// directory) is only possible because this app is **not sandboxed**.
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
    private static let geminiClientID = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    private static let geminiClientSecret = "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"
    private static let geminiTokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Public API

    /// The current credential as stored, without any network refresh. Refresh is
    /// driven reactively by `forceRefresh` after a request returns 401.
    ///
    /// `async` (and not actor-isolated) so the Keychain/file reads run off the
    /// main thread when called from the `@MainActor` store.
    static func credential(for provider: Provider) async -> Credential? {
        guard let loaded = load(provider) else { return nil }
        if let key = loaded.apiKey { return .apiKey(key) }
        return .oauth(accessToken: loaded.access, accountID: loaded.accountID)
    }

    /// Exchanges the refresh token for a new access token and writes it back to
    /// the CLI's store. Returns nil when there's no refresh token to use.
    static func forceRefresh(_ provider: Provider) async -> Credential? {
        guard let loaded = load(provider), loaded.refresh != nil,
              let refreshed = try? await refresh(loaded) else { return nil }
        return .oauth(accessToken: refreshed.access, accountID: refreshed.accountID)
    }

    // MARK: Loaded credential

    private enum Source { case claudeKeychain, claudeFile, codexFile, geminiFile, copilotConfig }

    private struct Loaded {
        var access: String
        var refresh: String?
        var accountID: String?
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
        case .gemini: return loadGemini()
        case .copilot: return loadCopilot()
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
        return Loaded(access: access, refresh: oauth["refreshToken"].string,
                      accountID: nil, source: source, apiKey: nil, raw: raw)
    }

    private static func claudeKeychainJSON() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Codex CLI

    private static func loadCodex() -> Loaded? {
        let file = home.appendingPathComponent(".codex/auth.json")
        guard let raw = readJSONObject(file) else { return nil }
        let root = JSON(raw)
        if let access = root["tokens"]["access_token"].string, !access.isEmpty {
            return Loaded(access: access, refresh: root["tokens"]["refresh_token"].string,
                          accountID: root["tokens"]["account_id"].string,
                          source: .codexFile, apiKey: nil, raw: raw)
        }
        if let key = root["OPENAI_API_KEY"].string, !key.isEmpty {
            return Loaded(access: "", refresh: nil, accountID: nil,
                          source: .codexFile, apiKey: key, raw: raw)
        }
        return nil
    }

    // MARK: Gemini CLI

    private static func loadGemini() -> Loaded? {
        let file = home.appendingPathComponent(".gemini/oauth_creds.json")
        if let raw = readJSONObject(file) {
            let root = JSON(raw)
            if let access = root["access_token"].string, !access.isEmpty {
                return Loaded(access: access, refresh: root["refresh_token"].string,
                              accountID: nil, source: .geminiFile, apiKey: nil, raw: raw)
            }
        }
        if let key = geminiAPIKey() {
            return Loaded(access: "", refresh: nil, accountID: nil,
                          source: .geminiFile, apiKey: key, raw: [:])
        }
        return nil
    }

    private static func geminiAPIKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty { return key }
        // ~/.gemini/.env: GEMINI_API_KEY=...
        let env = home.appendingPathComponent(".gemini/.env")
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if name == "GEMINI_API_KEY" || name == "GOOGLE_API_KEY" {
                return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
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
                        return Loaded(access: token, refresh: nil,
                                      accountID: entry["user"].string, source: .copilotConfig, apiKey: nil, raw: [:])
                    }
                }
            }
        }
        if let (token, user) = ghHostsToken() {
            return Loaded(access: token, refresh: nil,
                          accountID: user, source: .copilotConfig, apiKey: nil, raw: [:])
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
        case .geminiFile:
            return try await refreshGemini(loaded, refreshToken: refreshToken)
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

    private static func refreshGemini(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let form = [
            "client_id": geminiClientID,
            "client_secret": geminiClientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
        let result = try await HTTPClient.send(geminiTokenURL, method: "POST",
            headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(form.utf8))
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        updated.raw["access_token"] = access
        if let expiresIn = result.json["expires_in"].double {
            updated.raw["expiry_date"] = Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
        }
        persist(updated.raw, to: updated.source)
        return updated
    }

    // MARK: Write-back

    private static func persist(_ raw: [String: Any], to source: Source) {
        let pretty = source == .codexFile || source == .geminiFile
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
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        case .claudeFile:
            try? data.write(to: home.appendingPathComponent(".claude/.credentials.json"), options: .atomic)
        case .codexFile:
            try? data.write(to: home.appendingPathComponent(".codex/auth.json"), options: .atomic)
        case .geminiFile:
            try? data.write(to: home.appendingPathComponent(".gemini/oauth_creds.json"), options: .atomic)
        case .copilotConfig:
            break
        }
    }

    // MARK: Helpers

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
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
