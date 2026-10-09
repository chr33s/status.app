import Foundation
import Testing
@testable import status

/// Isolated defaults + temp folders so grants never touch the app's real ones.
private struct Sandbox {
    let defaults: UserDefaults
    let access: SecurityScopedAccess
    let root: URL

    init() throws {
        let suite = "status.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        access = SecurityScopedAccess(defaults: defaults, securityScoped: false)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func folder(_ name: String, files: [String: Any] = [:]) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, json) in files {
            try JSONSerialization.data(withJSONObject: json).write(to: url.appendingPathComponent(file))
        }
        return url
    }
}

struct SecurityScopedAccessTests {
    @Test func providersMapToResources() {
        #expect(Provider.claude.externalResource == .claudeData)
        #expect(Provider.codex.externalResource == .codexData)
        #expect(Provider.grok.externalResource == .grokData)
        #expect(Provider.copilot.externalResource == .githubConfig)
        #expect(Provider.antigravity.externalResource == nil)
        for resource in ExternalResource.allCases {
            #expect(resource.provider.externalResource == resource)
        }
    }

    @Test func relativePathsStayBeneathRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/grant/.codex", isDirectory: true)
        #expect(SecurityScopedAccess.file("auth.json", in: root)?.path == "/tmp/grant/.codex/auth.json")
        #expect(SecurityScopedAccess.file("sub/../auth.json", in: root)?.path == "/tmp/grant/.codex/auth.json")
        #expect(SecurityScopedAccess.file("../.claude/settings.json", in: root) == nil)
        #expect(SecurityScopedAccess.file("../../etc/passwd", in: root) == nil)
        #expect(SecurityScopedAccess.file("../.codex-other/auth.json", in: root) == nil)
    }

    @Test func missingBookmarkIsNotAuthorized() throws {
        let sandbox = try Sandbox()
        #expect(!sandbox.access.isAuthorized(.codexData))
        #expect(throws: SecurityScopedAccessError.notAuthorized(.codexData)) {
            try sandbox.access.withAccess(to: .codexData) { $0 }
        }
    }

    @Test func grantResolvesToSelectedFolder() throws {
        let sandbox = try Sandbox()
        let codex = try sandbox.folder(".codex")
        try sandbox.access.authorize(.codexData, url: codex)
        let resolved = try sandbox.access.withAccess(to: .codexData) { $0 }
        #expect(resolved.resolvingSymlinksInPath() == codex.resolvingSymlinksInPath())
    }

    @Test func replacingAndRevokingGrant() throws {
        let sandbox = try Sandbox()
        let first = try sandbox.folder("a/.codex")
        let second = try sandbox.folder("b/.codex")
        try sandbox.access.authorize(.codexData, url: first)
        try sandbox.access.authorize(.codexData, url: second)
        let resolved = try sandbox.access.withAccess(to: .codexData) { $0 }
        #expect(resolved.resolvingSymlinksInPath() == second.resolvingSymlinksInPath())

        sandbox.access.revoke(.codexData)
        #expect(throws: SecurityScopedAccessError.notAuthorized(.codexData)) {
            try sandbox.access.withAccess(to: .codexData) { $0 }
        }
    }

    @Test func deletedFolderNeedsGrantAgain() throws {
        let sandbox = try Sandbox()
        let codex = try sandbox.folder(".codex")
        try sandbox.access.authorize(.codexData, url: codex)
        try FileManager.default.removeItem(at: codex)
        #expect(throws: SecurityScopedAccessError.accessLost(.codexData)) {
            try sandbox.access.withAccess(to: .codexData) { $0 }
        }
        #expect(sandbox.access.isAuthorized(.codexData))
    }

    @Test func validationAcceptsExpectedFolders() throws {
        let sandbox = try Sandbox()
        // Empty but correctly named (fresh CLI install).
        #expect(ExternalResource.claudeData.validate(try sandbox.folder(".claude")) == nil)
        #expect(ExternalResource.githubConfig.validate(try sandbox.folder("gh")) == nil)
        #expect(ExternalResource.githubConfig.validate(try sandbox.folder("github-copilot")) == nil)
        // Renamed, but holding the CLI's files.
        #expect(ExternalResource.codexData.validate(try sandbox.folder("codex-home", files: ["auth.json": [:]])) == nil)
    }

    @Test func validationRejectsWrongFolders() throws {
        let sandbox = try Sandbox()
        let unrelated = try sandbox.folder("Documents")
        #expect(ExternalResource.codexData.validate(unrelated) != nil)

        // The parent of the right folder (home / .config) is too broad.
        let home = try sandbox.folder("home")
        _ = try sandbox.folder("home/.claude")
        let reason = try #require(ExternalResource.claudeData.validate(home))
        #expect(reason.contains(".claude"))
        let config = try sandbox.folder("config")
        _ = try sandbox.folder("config/gh")
        #expect(ExternalResource.githubConfig.validate(config) != nil)

        #expect(throws: SecurityScopedAccessError.self) {
            try sandbox.access.authorize(.codexData, url: unrelated)
        }
        #expect(!sandbox.access.isAuthorized(.codexData))
    }
}

/// Swaps `LocalCredentials.access`, `readKeychainItem`, and
/// `readKeychainItemViaSecurityTool`, which are global — so serialized. The
/// Keychain and the `security` tool are always stubbed so these never read
/// (or prompt for) the developer's real logins.
@Suite(.serialized)
struct LocalCredentialsAccessTests {
    private func withAccess(
        _ access: SecurityScopedAccess,
        keychain: [String: LocalCredentials.KeychainItem] = [:],
        securityTool: @escaping (String) -> Data? = { _ in nil },
        _ body: () async throws -> Void
    ) async rethrows {
        let originalAccess = LocalCredentials.access
        let originalKeychain = LocalCredentials.readKeychainItem
        let originalTool = LocalCredentials.readKeychainItemViaSecurityTool
        LocalCredentials.access = access
        LocalCredentials.readKeychainItem = { service, _ in keychain[service] }
        LocalCredentials.readKeychainItemViaSecurityTool = securityTool
        for provider in Provider.allCases { LocalCredentials.resetCache(for: provider) }
        defer {
            LocalCredentials.access = originalAccess
            LocalCredentials.readKeychainItem = originalKeychain
            LocalCredentials.readKeychainItemViaSecurityTool = originalTool
            for provider in Provider.allCases { LocalCredentials.resetCache(for: provider) }
        }
        try await body()
    }

    private func item(_ secret: String, account: String?) -> LocalCredentials.KeychainItem {
        LocalCredentials.KeychainItem(data: Data(secret.utf8), account: account)
    }

    // MARK: Claude Code

    private func claudeJSON(access: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": access, "refreshToken": "r", "subscriptionType": "max"],
        ])
    }

    @Test func claudeLoginIsReadThroughTheSecurityTool() async throws {
        let sandbox = try Sandbox()
        let json = try claudeJSON(access: "tool_token")
        var toolServices: [String] = []
        let originalKeychain = LocalCredentials.readKeychainItem
        defer { LocalCredentials.readKeychainItem = originalKeychain }
        try await withAccess(sandbox.access, securityTool: { service in
            toolServices.append(service)
            return json
        }) {
            // The direct read must not run: it is what prompts after a rotation.
            LocalCredentials.readKeychainItem = { _, _ in
                Issue.record("direct Keychain read must not happen when the security tool succeeds")
                return nil
            }
            let credential = try await LocalCredentials.credential(for: .claude)
            guard case let .oauth(token, _, display) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "tool_token")
            #expect(display == "Claude Max")
            // Cached: a second lookup doesn't spawn the tool again.
            _ = try await LocalCredentials.credential(for: .claude)
            #expect(toolServices == ["Claude Code-credentials"])
        }
    }

    @Test func claudeFallsBackToDirectKeychainReadWhenToolFails() async throws {
        let sandbox = try Sandbox()
        let keychain = ["Claude Code-credentials": LocalCredentials.KeychainItem(data: try claudeJSON(access: "direct_token"), account: "me")]
        try await withAccess(sandbox.access, keychain: keychain) {
            let credential = try await LocalCredentials.credential(for: .claude)
            guard case let .oauth(token, _, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "direct_token")
        }
    }

    @Test func claudeRefreshRereadsRotatedTokenThroughTheSecurityTool() async throws {
        let sandbox = try Sandbox()
        let rotated = try claudeJSON(access: "new")
        await withAccess(sandbox.access, securityTool: { _ in rotated }) {
            // The CLI rotated the token: the re-read (no prompt) picks it up.
            let stale = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            guard case let .oauth(token, _, _) = await LocalCredentials.forceRefresh(.claude, after: stale) else {
                Issue.record("expected the rotated token")
                return
            }
            #expect(token == "new")
            // Same token still stored: nothing to retry with, surface re-auth.
            let same = Credential.oauth(accessToken: "new", accountID: nil, displayName: nil)
            #expect(await LocalCredentials.forceRefresh(.claude, after: same) == nil)
        }
    }

    @Test func missingGrantIsDistinctFromMissingLogin() async throws {
        let sandbox = try Sandbox()
        try await withAccess(sandbox.access) {
            // No grant: Status can't tell whether the user is signed in.
            await #expect(throws: SecurityScopedAccessError.notAuthorized(.codexData)) {
                _ = try await LocalCredentials.credential(for: .codex)
            }
            // Granted but empty: genuinely not signed in.
            try sandbox.access.authorize(.codexData, url: try sandbox.folder(".codex"))
            #expect(try await LocalCredentials.credential(for: .codex) == nil)
        }
    }

    @Test func readsCredentialInsideGrantedFolder() async throws {
        let sandbox = try Sandbox()
        let codex = try sandbox.folder(".codex", files: [
            "auth.json": ["tokens": ["access_token": "access", "account_id": "acct"]],
        ])
        try sandbox.access.authorize(.codexData, url: codex)
        try await withAccess(sandbox.access) {
            let credential = try await LocalCredentials.credential(for: .codex)
            guard case let .oauth(token, account, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "access")
            #expect(account == "acct")
        }
    }

    @Test func readsGitHubHostsFromGhFolder() async throws {
        let sandbox = try Sandbox()
        let gh = try sandbox.folder("gh")
        try "github.com:\n    oauth_token: gho_token\n    user: octocat\n"
            .write(to: gh.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
        try sandbox.access.authorize(.githubConfig, url: gh)
        // Nothing in the Keychain: the granted folder is the fallback.
        try await withAccess(sandbox.access) {
            let credential = try await LocalCredentials.credential(for: .copilot)
            guard case let .oauth(token, user, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "gho_token")
            #expect(user == "octocat")
        }
    }

    @Test func copilotKeychainLoginNeedsNoFolderGrant() async throws {
        let sandbox = try Sandbox()
        // `copilot login` files the token under `https://github.com:<login>`.
        let keychain = ["copilot-cli": item("gho_cli", account: "https://github.com:octocat")]
        try await withAccess(sandbox.access, keychain: keychain) {
            let credential = try await LocalCredentials.credential(for: .copilot)
            guard case let .oauth(token, user, display) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "gho_cli")
            #expect(user == "octocat")
            #expect(display == "octocat")
            #expect(!sandbox.access.isAuthorized(.githubConfig))
        }
    }

    @Test func ghKeychainLoginIsUnwrappedAndPreferredOverFolder() async throws {
        let sandbox = try Sandbox()
        let gh = try sandbox.folder("gh")
        try "github.com:\n    oauth_token: gho_file\n    user: filer\n"
            .write(to: gh.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)
        try sandbox.access.authorize(.githubConfig, url: gh)
        // gh stores through Go's keyring, which base64-wraps the value.
        let wrapped = "go-keyring-base64:" + Data("gho_gh".utf8).base64EncodedString()
        let keychain = ["gh:github.com": item(wrapped, account: "octocat")]
        try await withAccess(sandbox.access, keychain: keychain) {
            let credential = try await LocalCredentials.credential(for: .copilot)
            guard case let .oauth(token, user, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "gho_gh")
            #expect(user == "octocat")
        }
    }

    private func codexAuth(access: String, refresh: String = "r", lastRefresh: String?) -> [String: Any] {
        var json: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": ["access_token": access, "refresh_token": refresh, "account_id": "acct"],
        ]
        if let lastRefresh { json["last_refresh"] = lastRefresh }
        return json
    }

    private func codexKeychain(_ json: [String: Any], account: String = "cli|199c3b95ffbb66f1") throws -> [String: LocalCredentials.KeychainItem] {
        ["Codex Auth": LocalCredentials.KeychainItem(data: try JSONSerialization.data(withJSONObject: json), account: account)]
    }

    @Test func codexKeychainLoginNeedsNoFolderGrant() async throws {
        let sandbox = try Sandbox()
        let keychain = try codexKeychain(codexAuth(access: "kc", lastRefresh: "2026-09-26T06:50:59.123Z"))
        try await withAccess(sandbox.access, keychain: keychain) {
            let credential = try await LocalCredentials.credential(for: .codex)
            guard case let .oauth(token, account, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == "kc")
            #expect(account == "acct")
            #expect(!sandbox.access.isAuthorized(.codexData))
        }
    }

    @Test func codexIgnoresKeychainItemsThatAreNotTheCLIs() async throws {
        let sandbox = try Sandbox()
        let keychain = try codexKeychain(codexAuth(access: "other", lastRefresh: nil), account: "something-else")
        await withAccess(sandbox.access, keychain: keychain) {
            // Not the CLI's item, and no folder grant: access is still required.
            await #expect(throws: SecurityScopedAccessError.notAuthorized(.codexData)) {
                _ = try await LocalCredentials.credential(for: .codex)
            }
        }
    }

    @Test(arguments: [
        // (keychain last_refresh, file last_refresh, expected winner)
        ("2026-09-26T06:50:59.123Z", "2026-09-26T05:54:00Z", "kc"),
        ("2026-09-26T05:54:00.000Z", "2026-09-26T06:50:59Z", "file"),
        (nil, "2026-09-26T06:50:59Z", "file"),
        ("2026-09-26T06:50:59.123Z", nil, "kc"),
    ] as [(String?, String?, String)])
    func codexNewerStoreWinsWhenBothExist(keychainStamp: String?, fileStamp: String?, winner: String) async throws {
        let sandbox = try Sandbox()
        let codex = try sandbox.folder(".codex", files: ["auth.json": codexAuth(access: "file", lastRefresh: fileStamp)])
        try sandbox.access.authorize(.codexData, url: codex)
        let keychain = try codexKeychain(codexAuth(access: "kc", lastRefresh: keychainStamp))
        try await withAccess(sandbox.access, keychain: keychain) {
            let credential = try await LocalCredentials.credential(for: .codex)
            guard case let .oauth(token, _, _) = credential else {
                Issue.record("expected an OAuth credential, got \(String(describing: credential))")
                return
            }
            #expect(token == winner)
        }
    }

    @Test func codexKeychainRefreshOnlyRereads() async throws {
        let sandbox = try Sandbox()
        let keychain = try codexKeychain(codexAuth(access: "kc_new", lastRefresh: "2026-09-26T06:50:59.123Z"))
        await withAccess(sandbox.access, keychain: keychain) {
            // The CLI rotated the token: the re-read picks it up.
            let stale = Credential.oauth(accessToken: "kc_old", accountID: "acct", displayName: nil)
            guard case let .oauth(token, _, _) = await LocalCredentials.forceRefresh(.codex, after: stale) else {
                Issue.record("expected the rotated token")
                return
            }
            #expect(token == "kc_new")
            // Same token still stored: never exchange the Keychain refresh
            // token ourselves, so there's nothing to retry with.
            let same = Credential.oauth(accessToken: "kc_new", accountID: "acct", displayName: nil)
            #expect(await LocalCredentials.forceRefresh(.codex, after: same) == nil)
        }
    }

    @Test func copilotRefreshRereadsRotatedKeychainToken() async throws {
        let sandbox = try Sandbox()
        let keychain = ["copilot-cli": item("gho_new", account: "https://github.com:octocat")]
        await withAccess(sandbox.access, keychain: keychain) {
            let stale = Credential.oauth(accessToken: "gho_old", accountID: "octocat", displayName: "octocat")
            let refreshed = await LocalCredentials.forceRefresh(.copilot, after: stale)
            guard case let .oauth(token, _, _) = refreshed else {
                Issue.record("expected the rotated token, got \(String(describing: refreshed))")
                return
            }
            #expect(token == "gho_new")
            // The same stale token again is not worth retrying.
            let unchanged = Credential.oauth(accessToken: "gho_new", accountID: "octocat", displayName: "octocat")
            #expect(await LocalCredentials.forceRefresh(.copilot, after: unchanged) == nil)
        }
    }

    @Test func codexRefreshPersistsRotationAndPreservesMetadata() async throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder(".codex", files: ["auth.json": codexAuth(access: "old", lastRefresh: nil)])
        try sandbox.access.authorize(.codexData, url: folder)
        let originalRequest = LocalCredentials.refreshRequest
        defer { LocalCredentials.refreshRequest = originalRequest }
        LocalCredentials.refreshRequest = { _, _, _ in
            // A CLI configuration edit made while the exchange was pending.
            var raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("auth.json"))) as? [String: Any])
            raw["new_metadata"] = "keep"
            try JSONSerialization.data(withJSONObject: raw).write(to: folder.appendingPathComponent("auth.json"))
            return .stub(["access_token": "new", "refresh_token": "rotated"])
        }
        try await withAccess(sandbox.access) {
            let failed = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            let credential = await LocalCredentials.forceRefresh(.codex, after: failed)
            guard case let .oauth(token, _, _) = credential else { Issue.record("expected rotation"); return }
            #expect(token == "new")
            let json = JSON(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("auth.json"))))
            #expect(json["tokens"]["refresh_token"].string == "rotated")
            #expect(json["new_metadata"].string == "keep")
        }
    }

    @Test func concurrentCLIRotationWinsOverOurRefresh() async throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder(".codex", files: ["auth.json": codexAuth(access: "old", lastRefresh: nil)])
        try sandbox.access.authorize(.codexData, url: folder)
        let originalRequest = LocalCredentials.refreshRequest
        defer { LocalCredentials.refreshRequest = originalRequest }
        let cliRaw = codexAuth(access: "cli_new", refresh: "cli_refresh", lastRefresh: nil)
        let cliData = try JSONSerialization.data(withJSONObject: cliRaw)
        LocalCredentials.refreshRequest = { _, _, _ in
            try cliData.write(to: folder.appendingPathComponent("auth.json"))
            return .stub(["access_token": "our_new", "refresh_token": "our_refresh"])
        }
        await withAccess(sandbox.access) {
            let failed = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            guard case let .oauth(token, _, _) = await LocalCredentials.forceRefresh(.codex, after: failed) else {
                Issue.record("expected CLI rotation"); return
            }
            #expect(token == "cli_new")
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("auth.json")) == cliData)
    }

    @Test func failedWriteBackDoesNotReportSuccessfulRefresh() async throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder(".codex", files: ["auth.json": codexAuth(access: "old", lastRefresh: nil)])
        try sandbox.access.authorize(.codexData, url: folder)
        let originalRequest = LocalCredentials.refreshRequest
        defer { LocalCredentials.refreshRequest = originalRequest }
        LocalCredentials.refreshRequest = { _, _, _ in
            // Simulate the folder grant being removed during the request.
            sandbox.access.revoke(.codexData)
            return .stub(["access_token": "new", "refresh_token": "rotated"])
        }
        await withAccess(sandbox.access) {
            let failed = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            #expect(await LocalCredentials.forceRefresh(.codex, after: failed) == nil)
        }
    }

    @Test func unwritableDirectoryPreventsSpendingARefreshToken() async throws {
        let sandbox = try Sandbox()
        let folder = try sandbox.folder(".codex", files: ["auth.json": codexAuth(access: "old", lastRefresh: nil)])
        try sandbox.access.authorize(.codexData, url: folder)
        let originalRequest = LocalCredentials.refreshRequest
        defer {
            LocalCredentials.refreshRequest = originalRequest
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        LocalCredentials.refreshRequest = { _, _, _ in
            Issue.record("must not exchange a token when atomic write-back cannot create a file")
            return .stub(["access_token": "new"])
        }
        await withAccess(sandbox.access) {
            let failed = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            #expect(await LocalCredentials.forceRefresh(.codex, after: failed) == nil)
        }
    }

    @Test func grokRefreshUpdatesTheSameEntryAndPreservesOtherLogins() async throws {
        let sandbox = try Sandbox()
        let key = "https://auth.x.ai::a"
        let otherKey = "https://auth.x.ai::z"
        let folder = try sandbox.folder(".grok", files: ["auth.json": [
            key: ["key": "old", "refresh_token": "r", "email": "me@example.com"],
            otherKey: ["key": "other", "refresh_token": "other_refresh"],
        ]])
        try sandbox.access.authorize(.grokData, url: folder)
        let originalRequest = LocalCredentials.refreshRequest
        defer { LocalCredentials.refreshRequest = originalRequest }
        LocalCredentials.refreshRequest = { _, headers, body in
            #expect(headers["Content-Type"] == "application/x-www-form-urlencoded")
            #expect(String(data: body, encoding: .utf8)?.contains("client_id=a") == true)
            return .stub(["access_token": "new", "refresh_token": "rotated", "expires_in": 3600])
        }
        try await withAccess(sandbox.access) {
            let failed = Credential.oauth(accessToken: "old", accountID: nil, displayName: nil)
            guard case let .oauth(token, _, _) = await LocalCredentials.forceRefresh(.grok, after: failed) else {
                Issue.record("expected Grok rotation"); return
            }
            #expect(token == "new")
            let json = JSON(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("auth.json"))))
            #expect(json[key]["refresh_token"].string == "rotated")
            #expect(json[key]["email"].string == "me@example.com")
            #expect(json[otherKey]["key"].string == "other")
            #expect(json[otherKey]["refresh_token"].string == "other_refresh")
        }
    }
}
