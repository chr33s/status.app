import Foundation

/// A CLI data folder outside the sandbox container. Status can only read one
/// after the user selects it in an open panel; the grant is remembered as a
/// security-scoped bookmark (see `SecurityScopedAccess`).
///
/// Filesystem audit (everything Status touches outside its container):
///
/// | Resource       | File                                  | Access |
/// | -------------- | ------------------------------------- | ------ |
/// | `claudeData`   | `.credentials.json` (Keychain fallback) | read |
/// |                | `settings.json` (telemetry auto-config) | read/write |
/// | `codexData`    | `auth.json`                            | read, write-back of refreshed tokens (not needed when the login is in the `Codex Auth` Keychain item) |
/// | `grokData`     | `auth.json`                            | read, write-back of refreshed tokens |
/// | `githubConfig` | `hosts.yml` (gh) or `apps.json` / `hosts.json` (github-copilot) | read (fallback when neither the `copilot-cli` nor `gh:github.com` Keychain item exists) |
///
/// Antigravity's login lives only in the Keychain, so it has no resource.
enum ExternalResource: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeData
    case codexData
    case grokData
    case githubConfig

    var id: String { rawValue }

    /// The provider whose login lives in this folder.
    var provider: Provider {
        switch self {
        case .claudeData: return .claude
        case .codexData: return .codex
        case .grokData: return .grok
        case .githubConfig: return .copilot
        }
    }

    /// Name of the tool that owns the folder, for prompts.
    var owner: String {
        switch self {
        case .githubConfig: return "GitHub CLI"
        default: return provider.cliName
        }
    }

    /// The folder's name, as shown on the "Choose … Folder" button.
    var folderName: String {
        switch self {
        case .claudeData: return ".claude"
        case .codexData: return ".codex"
        case .grokData: return ".grok"
        case .githubConfig: return "gh"
        }
    }

    /// Where the CLI keeps the folder by default, relative to the home folder.
    var defaultRelativePath: String {
        switch self {
        case .githubConfig: return ".config/gh"
        default: return folderName
        }
    }

    var expectedPath: String { "~/" + defaultRelativePath }

    var defaultLocation: URL {
        FileManager.default.realHomeDirectoryForCurrentUser.appendingPathComponent(defaultRelativePath, isDirectory: true)
    }

    /// Why Status wants the folder, shown in the prompt and the open panel.
    var accessExplanation: String {
        switch self {
        case .githubConfig:
            return "Status reads your existing GitHub CLI login from its config folder. Choose your gh folder (or github-copilot) inside .config to allow Status to access it."
        case .codexData:
            return "Status reads your existing Codex login from its data folder. Choose your .codex folder to allow Status to access it. Alternatively, set cli_auth_credentials_store = \"keyring\" in ~/.codex/config.toml and run codex login again — Status then reads the login from the Keychain and needs no folder."
        default:
            return "Status reads your existing \(owner) login from its data folder. Choose your \(folderName) folder to allow Status to access it."
        }
    }

    /// Folder names that identify the resource even when it's empty (a fresh
    /// CLI install), and files/folders that identify it under any name (a
    /// relocated `CODEX_HOME`, `XDG_CONFIG_HOME`, …).
    private var acceptedNames: Set<String> {
        switch self {
        case .claudeData: return [".claude"]
        case .codexData: return [".codex"]
        case .grokData: return [".grok"]
        case .githubConfig: return ["gh", "github-copilot"]
        }
    }

    private var markers: [String] {
        switch self {
        case .claudeData: return [".credentials.json", "settings.json", "projects"]
        case .codexData: return ["auth.json", "config.toml", "sessions"]
        case .grokData: return ["auth.json"]
        case .githubConfig: return ["hosts.yml", "apps.json", "hosts.json"]
        }
    }

    /// Returns nil when `url` plausibly is this resource's folder, else a
    /// user-facing reason the selection was rejected.
    func validate(_ url: URL, fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "Choose a folder, not a file."
        }
        if acceptedNames.contains(url.lastPathComponent) { return nil }
        if markers.contains(where: { fileManager.fileExists(atPath: url.appendingPathComponent($0).path) }) {
            return nil
        }
        // A common slip: picking the parent (home or .config) instead.
        if let child = acceptedNames.sorted().first(where: {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }) {
            return "“\(url.lastPathComponent)” contains your \(child) folder. Choose the \(child) folder itself so Status only gets access to what it needs."
        }
        return "“\(url.lastPathComponent)” doesn't look like the \(owner) folder. Choose the folder at \(expectedPath)."
    }
}

extension Provider {
    /// The CLI folder this provider reads its login from; nil when the login
    /// lives only in the Keychain.
    var externalResource: ExternalResource? {
        switch self {
        case .claude: return .claudeData
        case .codex: return .codexData
        case .grok: return .grokData
        case .copilot: return .githubConfig
        case .antigravity: return nil
        }
    }
}

enum SecurityScopedAccessError: LocalizedError, Equatable {
    /// The user hasn't granted access to the folder yet.
    case notAuthorized(ExternalResource)
    /// A grant exists but can no longer be used (folder moved/deleted, or
    /// access revoked); the user must choose the folder again.
    case accessLost(ExternalResource)
    /// The user picked a folder that doesn't look like the resource.
    case invalidSelection(ExternalResource, reason: String)

    var resource: ExternalResource {
        switch self {
        case let .notAuthorized(resource), let .accessLost(resource), let .invalidSelection(resource, _):
            return resource
        }
    }

    var errorDescription: String? {
        switch self {
        case let .notAuthorized(resource):
            return "Status needs access to your \(resource.folderName) folder."
        case let .accessLost(resource):
            return "Access to your \(resource.folderName) folder needs to be granted again."
        case let .invalidSelection(_, reason):
            return reason
        }
    }
}

/// The single owner of security-scoped bookmarks for user-selected CLI
/// folders: creates them from the user's selection, persists them in
/// `UserDefaults`, resolves (and refreshes stale) bookmarks on later
/// launches, and brackets every filesystem operation with
/// start/stopAccessingSecurityScopedResource.
final class SecurityScopedAccess: @unchecked Sendable {
    static let shared = SecurityScopedAccess()

    private let defaults: UserDefaults
    private let securityScoped: Bool

    /// - Parameter securityScoped: false only in tests, which create plain
    ///   bookmarks so they don't depend on the sandbox's bookmark agent.
    init(defaults: UserDefaults = .standard, securityScoped: Bool = true) {
        self.defaults = defaults
        self.securityScoped = securityScoped
    }

    private func key(_ resource: ExternalResource) -> String { "bookmark.\(resource.rawValue)" }

    private var creationOptions: URL.BookmarkCreationOptions {
        securityScoped ? [.withSecurityScope] : []
    }

    private var resolutionOptions: URL.BookmarkResolutionOptions {
        securityScoped ? [.withSecurityScope] : []
    }

    // MARK: Grants

    func isAuthorized(_ resource: ExternalResource) -> Bool {
        defaults.data(forKey: key(resource)) != nil
    }

    /// The granted folder's current location, for display. Nil without a
    /// grant or when the bookmark no longer resolves.
    func authorizedURL(_ resource: ExternalResource) -> URL? {
        guard let data = defaults.data(forKey: key(resource)) else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// Persists the user's selection as the grant for `resource`, replacing
    /// any earlier one. `url` must come from an open panel, which is what
    /// makes it bookmarkable inside the sandbox.
    func authorize(_ resource: ExternalResource, url: URL) throws {
        if let reason = resource.validate(url) {
            throw SecurityScopedAccessError.invalidSelection(resource, reason: reason)
        }
        let data = try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(data, forKey: key(resource))
    }

    func revoke(_ resource: ExternalResource) {
        defaults.removeObject(forKey: key(resource))
    }

    // MARK: Access

    /// Runs `operation` with the granted folder's URL while security-scoped
    /// access is active, stopping access afterwards on every path.
    func withAccess<T>(to resource: ExternalResource, _ operation: (URL) throws -> T) throws -> T {
        let root = try beginAccess(resource)
        defer { endAccess(root) }
        return try operation(root)
    }

    private func beginAccess(_ resource: ExternalResource) throws -> URL {
        guard let data = defaults.data(forKey: key(resource)) else {
            throw SecurityScopedAccessError.notAuthorized(resource)
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            throw SecurityScopedAccessError.accessLost(resource)
        }
        if securityScoped, !url.startAccessingSecurityScopedResource() {
            throw SecurityScopedAccessError.accessLost(resource)
        }
        // Bookmarks follow a moved folder, including into the Trash; a folder
        // that's gone or trashed is no longer the one the CLI uses.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, !url.path.contains("/.Trash/") else {
            endAccess(url)
            throw SecurityScopedAccessError.accessLost(resource)
        }
        if stale, let fresh = try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: key(resource))
        }
        return url
    }

    private func endAccess(_ url: URL) {
        if securityScoped { url.stopAccessingSecurityScopedResource() }
    }

    /// `relativePath` under `root`, or nil if it would escape it (`..`).
    static func file(_ relativePath: String, in root: URL) -> URL? {
        let base = root.standardizedFileURL
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        return candidate.path.hasPrefix(prefix) ? candidate : nil
    }
}

extension FileManager {
    /// The user's real home directory. In a sandboxed app,
    /// `homeDirectoryForCurrentUser` points at the app *container*
    /// (~/Library/Containers/…/Data). Only used to point the folder picker at
    /// a CLI folder's default location — reading it still needs a user grant.
    var realHomeDirectoryForCurrentUser: URL {
        if let dir = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return homeDirectoryForCurrentUser
    }
}
