import Foundation
import Security

/// Reads (and, when expired, refreshes) the existing logins of the Claude Code
/// and Codex CLIs so the app can show real subscription session limits without
/// asking for an API key.
///
/// Reading these locations (another app's Keychain item, files under the home
/// directory) is only possible because this app is **not sandboxed**.
///
/// ── Token refresh ──
/// OAuth access tokens expire. When a stored token is past (or near) its expiry,
/// or a request comes back 401, we exchange the refresh token for a new one and
/// **write it back to the same store** so the rotation stays consistent with the
/// CLI. The OAuth client ids / token endpoints below are observed from the CLIs
/// and may change — they're isolated here. If write-back fails we still use the
/// fresh token for the current session (the CLI will re-authenticate as needed).
enum LocalCredentials {
    // Observed public OAuth clients for the two CLIs. Verify if a CLI updates.
    private static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let claudeTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let codexTokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Public API

    static func exists(_ provider: Provider) -> Bool {
        if load(provider) != nil { return true }
        if provider == .codex, codexAPIKey() != nil { return true }
        return false
    }

    /// Returns a usable credential, refreshing first if the token is expired.
    static func freshCredential(_ provider: Provider) async -> Credential? {
        guard var loaded = load(provider) else {
            // Codex configured with a plain API key rather than a ChatGPT login.
            if provider == .codex, let key = codexAPIKey() { return .apiKey(key) }
            return nil
        }
        if loaded.isExpired, loaded.refresh != nil, let refreshed = try? await refresh(loaded) {
            loaded = refreshed
        }
        return .oauth(accessToken: loaded.access, accountID: loaded.accountID)
    }

    /// Forces a refresh regardless of expiry (used after a 401), then returns the
    /// new credential.
    static func forceRefresh(_ provider: Provider) async -> Credential? {
        guard let loaded = load(provider), loaded.refresh != nil,
              let refreshed = try? await refresh(loaded) else { return nil }
        return .oauth(accessToken: refreshed.access, accountID: refreshed.accountID)
    }

    // MARK: Loaded credential

    private enum Source { case claudeKeychain, claudeFile, codexFile }

    private struct Loaded {
        var access: String
        var refresh: String?
        var expiresAt: Date?
        var accountID: String?
        var source: Source
        /// Full original JSON, preserved so write-back only touches token fields.
        var raw: [String: Any]

        /// Expired (with a 60s safety margin) — or unknown expiry treated as fresh.
        var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date().addingTimeInterval(60) >= expiresAt
        }
    }

    private static func load(_ provider: Provider) -> Loaded? {
        switch provider {
        case .claude: return loadClaude()
        case .codex: return loadCodex()
        default: return nil
        }
    }

    // MARK: Claude Code

    private static func loadClaude() -> Loaded? {
        if let raw = claudeKeychainJSON(), let loaded = parseClaude(raw, source: .claudeKeychain) {
            return loaded
        }
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let loaded = parseClaude(raw, source: .claudeFile) {
            return loaded
        }
        return nil
    }

    private static func parseClaude(_ raw: [String: Any], source: Source) -> Loaded? {
        let root = JSON(raw)
        let oauth = root["claudeAiOauth"]
        guard let access = oauth["accessToken"].string ?? root["accessToken"].string,
              !access.isEmpty else { return nil }
        // expiresAt is milliseconds since epoch.
        let expiresAt = oauth["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
        return Loaded(
            access: access,
            refresh: oauth["refreshToken"].string,
            expiresAt: expiresAt,
            accountID: nil,
            source: source,
            raw: raw
        )
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
        guard let data = try? Data(contentsOf: file),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let root = JSON(raw)
        guard let access = root["tokens"]["access_token"].string, !access.isEmpty else { return nil }
        return Loaded(
            access: access,
            refresh: root["tokens"]["refresh_token"].string,
            expiresAt: jwtExpiry(access),
            accountID: root["tokens"]["account_id"].string,
            source: .codexFile,
            raw: raw
        )
    }

    private static func codexAPIKey() -> String? {
        let file = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let key = JSON(raw)["OPENAI_API_KEY"].string, !key.isEmpty else { return nil }
        return key
    }

    // MARK: Refresh

    private static func refresh(_ loaded: Loaded) async throws -> Loaded {
        guard let refreshToken = loaded.refresh else { return loaded }
        switch loaded.source {
        case .claudeKeychain, .claudeFile:
            return try await refreshClaude(loaded, refreshToken: refreshToken)
        case .codexFile:
            return try await refreshCodex(loaded, refreshToken: refreshToken)
        }
    }

    private static func refreshClaude(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": claudeClientID,
        ])
        let result = try await HTTPClient.send(
            claudeTokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body
        )
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        if let expiresIn = result.json["expires_in"].double {
            updated.expiresAt = Date().addingTimeInterval(expiresIn)
        }

        // Preserve all other fields; only rewrite the oauth token block.
        var oauth = (updated.raw["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = updated.access
        if let refresh = updated.refresh { oauth["refreshToken"] = refresh }
        if let expiresAt = updated.expiresAt { oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000 }
        updated.raw["claudeAiOauth"] = oauth
        persistClaude(updated)
        return updated
    }

    private static func refreshCodex(_ loaded: Loaded, refreshToken: String) async throws -> Loaded {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": codexClientID,
        ])
        let result = try await HTTPClient.send(
            codexTokenURL, method: "POST",
            headers: ["Content-Type": "application/json"], body: body
        )
        guard let access = result.json["access_token"].string else { return loaded }

        var updated = loaded
        updated.access = access
        updated.refresh = result.json["refresh_token"].string ?? loaded.refresh
        updated.expiresAt = jwtExpiry(access)

        var tokens = (updated.raw["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = updated.access
        if let idToken = result.json["id_token"].string { tokens["id_token"] = idToken }
        if let refresh = updated.refresh { tokens["refresh_token"] = refresh }
        updated.raw["tokens"] = tokens
        updated.raw["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        persistCodex(updated)
        return updated
    }

    // MARK: Write-back

    private static func persistClaude(_ loaded: Loaded) {
        guard let data = try? JSONSerialization.data(withJSONObject: loaded.raw) else { return }
        switch loaded.source {
        case .claudeKeychain:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Claude Code-credentials",
            ]
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        case .claudeFile:
            try? data.write(to: home.appendingPathComponent(".claude/.credentials.json"), options: .atomic)
        case .codexFile:
            break
        }
    }

    private static func persistCodex(_ loaded: Loaded) {
        guard let data = try? JSONSerialization.data(withJSONObject: loaded.raw, options: .prettyPrinted) else { return }
        try? data.write(to: home.appendingPathComponent(".codex/auth.json"), options: .atomic)
    }

    // MARK: Helpers

    /// Decodes the `exp` claim from a JWT access/id token.
    private static func jwtExpiry(_ token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data),
              let exp = JSON(json)["exp"].double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
