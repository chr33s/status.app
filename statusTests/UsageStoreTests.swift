import Foundation
import Testing
@testable import status

@MainActor
struct UsageStoreTests {
    private func makeIsolatedSettings() -> AppSettings {
        let suiteName = "statusTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }

    @Test func concurrentRefreshesJoinAndRecheckWaitsForFreshCredentials() async {
        var reads = 0
        var release: CheckedContinuation<Void, Never>?
        let store = UsageStore(
            settings: makeIsolatedSettings(),
            loadCredential: { _ in
                reads += 1
                return .apiKey("test")
            },
            fetchUsage: { _, _ in
                if reads == 1 { await withCheckedContinuation { release = $0 } }
                return .notice(plan: nil, "read \(reads)")
            }
        )
        let first = Task { await store.refresh(.grok) }
        while release == nil { await Task.yield() }
        let joined = Task { await store.refresh(.grok) }
        let recheck = Task { await store.refresh(.grok, resetCache: true) }
        // Let both callers reach the suspended fetch.
        for _ in 0..<10 { await Task.yield() }
        #expect(reads == 1)
        release?.resume()
        await first.value
        await joined.value
        await recheck.value
        #expect(reads == 2)
        #expect(store.state(for: .grok).snapshot?.note == "read 2")
    }

    @Test func networkFailureRetainsLastGoodSnapshot() async {
        var shouldFail = false
        let store = UsageStore(
            settings: makeIsolatedSettings(),
            loadCredential: { _ in .apiKey("test") },
            fetchUsage: { _, _ in
                if shouldFail { throw URLError(.timedOut) }
                return .notice(plan: "test", "last good usage")
            }
        )
        await store.refresh(.grok)
        shouldFail = true
        await store.refresh(.grok)
        #expect(store.state(for: .grok).snapshot?.note == "last good usage")
        #expect(store.state(for: .grok).needsAttention)
    }

    @Test func disabledProviderIsSkippedAndSwitchesSelection() async {
        let settings = makeIsolatedSettings()
        var refreshed: Set<Provider> = []
        let store = UsageStore(
            settings: settings,
            loadCredential: { _ in .apiKey("test") },
            fetchUsage: { provider, _ in
                refreshed.insert(provider)
                var snapshot = UsageSnapshot(planName: "Pro")
                snapshot.sections = [UsageSection(title: "Session", fraction: provider == .codex ? 0.9 : 0.4, leading: "")]
                return snapshot
            }
        )

        store.setEnabled(false, for: .codex)
        #expect(!store.isEnabled(.codex))
        #expect(store.selected != .codex)

        await store.refreshAll()
        #expect(!refreshed.contains(.codex))
        #expect(refreshed.contains(.claude))
        #expect(store.peakFraction == 0.4)
    }
}
