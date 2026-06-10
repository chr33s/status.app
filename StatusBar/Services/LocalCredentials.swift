import Foundation
import Security

/// Reads the existing logins of the Claude Code and Codex CLIs so the app can
/// show *real* subscription session limits without asking for an API key.
///
/// Reading these locations (another app's Keychain item, files under the home
/// directory) is only possible because this app is **not sandboxed**. The first
/// time it reads the Claude Code Keychain item, macOS may prompt the user to
/// allow access.
enum LocalCredentials {
    static func resolve(_ provider: Provider) -> Credential? {
        switch provider {
        case .claude: return claude()
        case .codex: return codex()
        default: return nil
        }
    }

    static func exists(_ provider: Provider) -> Bool {
        resolve(provider) != nil
    }

    private static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Claude Code

    /// Claude Code stores OAuth credentials in the macOS Keychain (service
    /// "Claude Code-credentials"); on other platforms / older versions it uses
    /// `~/.claude/.credentials.json`. Both wrap a `claudeAiOauth` object.
    private static func claude() -> Credential? {
        if let token = claudeToken(from: claudeKeychainJSON()) { return token }
        let file = home.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data),
           let token = claudeToken(from: json) {
            return token
        }
        return nil
    }

    private static func claudeToken(from json: Any?) -> Credential? {
        let root = JSON(json)
        let oauth = root["claudeAiOauth"]
        guard let access = oauth["accessToken"].string ?? root["accessToken"].string,
              !access.isEmpty else { return nil }
        return .oauth(accessToken: access, accountID: nil)
    }

    private static func claudeKeychainJSON() -> Any? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Codex CLI

    /// Codex stores `~/.codex/auth.json`, which holds either an `OPENAI_API_KEY`
    /// or ChatGPT OAuth `tokens` (`access_token`, `account_id`).
    private static func codex() -> Credential? {
        let file = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let root = JSON(json)

        if let access = root["tokens"]["access_token"].string, !access.isEmpty {
            let accountID = root["tokens"]["account_id"].string
            return .oauth(accessToken: access, accountID: accountID)
        }
        if let key = root["OPENAI_API_KEY"].string, !key.isEmpty {
            return .apiKey(key)
        }
        return nil
    }
}
