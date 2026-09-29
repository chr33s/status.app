import Foundation

/// Lifecycle of a single provider's usage fetch.
enum LoadState: Sendable {
    /// Status can't look for the CLI login because the user hasn't granted
    /// (or has lost) access to the CLI's folder. Distinct from `notConfigured`:
    /// the user may well be signed in. `lost` is true when an earlier grant
    /// stopped working and must be given again.
    case authorizationRequired(ExternalResource, lost: Bool)
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
        switch self {
        case .notConfigured, .authorizationRequired: return false
        default: return true
        }
    }

    /// True for states that should surface a re-authenticate affordance.
    var needsAttention: Bool {
        switch self {
        case .authorizationRequired, .notConfigured, .needsReauth, .failed: return true
        default: return false
        }
    }
}
