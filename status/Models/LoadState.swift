import Foundation

/// Lifecycle of a single provider's usage fetch.
enum LoadState: Sendable {
    /// No CLI login found at all.
    case notConfigured
    case loading
    case loaded(UsageSnapshot)
    /// A login exists but its token is expired/invalid and couldn't be
    /// refreshed — the user should re-authenticate the CLI. Carries the last
    /// good snapshot (if any) so the UI keeps showing usage, marked stale.
    case needsReauth(String, stale: UsageSnapshot?)
    /// The fetch failed (network, decoding, …). Also keeps the last good
    /// snapshot so a transient error doesn't blank out the meters.
    case failed(String, stale: UsageSnapshot?)

    var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot): return snapshot
        case let .needsReauth(_, stale), let .failed(_, stale): return stale
        default: return nil
        }
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
