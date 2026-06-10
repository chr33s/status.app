import Foundation

/// Lifecycle of a single provider's usage fetch.
enum LoadState: Sendable {
    case notConfigured
    case loading
    case loaded(UsageSnapshot)
    case failed(String)

    var snapshot: UsageSnapshot? {
        if case let .loaded(snapshot) = self { return snapshot }
        return nil
    }

    var isConfigured: Bool {
        if case .notConfigured = self { return false }
        return true
    }
}
