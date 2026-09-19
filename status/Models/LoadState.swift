import Foundation

/// Lifecycle of a single provider's usage fetch.
enum LoadState: Sendable {
    /// No CLI login found at all.
    case notConfigured
    case loading
    case loaded(UsageSnapshot)
    /// A login exists but its token is expired/invalid and couldn't be
    /// refreshed — the user should re-authenticate the CLI.
    case needsReauth(String)
    case failed(String)

    var snapshot: UsageSnapshot? {
        if case let .loaded(snapshot) = self { return snapshot }
        return nil
    }

    /// True once a CLI login exists (even if it now needs re-auth).
    var isConfigured: Bool {
        if case .notConfigured = self { return false }
        return true
    }

    /// True for states that should surface a re-authenticate affordance.
    var needsAttention: Bool {
        switch self {
        case .notConfigured, .needsReauth, .failed: return true
        default: return false
        }
    }
}
