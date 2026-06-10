import Foundation
import SwiftUI

/// Owns per-provider load state, the selected tab, and the refresh schedule.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var states: [Provider: LoadState] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var isRefreshing = false
    @Published var selected: Provider = .codex

    private let settings = AppSettings.shared
    private var timer: Timer?
    private var didStart = false
    private var didAutoSelect = false

    init() {
        // Seed as loading without touching the Keychain/disk on the main thread;
        // the first refresh resolves real state asynchronously.
        for provider in Provider.allCases {
            states[provider] = .loading
        }
    }

    func state(for provider: Provider) -> LoadState {
        states[provider] ?? .notConfigured
    }

    // MARK: Refresh

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: Void.self) { group in
            for provider in Provider.allCases {
                group.addTask { await self.refresh(provider) }
            }
        }
        lastRefresh = Date()
        autoSelectFirstConfigured()
    }

    /// The first time any provider is signed in, switch to it if the current
    /// selection isn't configured.
    private func autoSelectFirstConfigured() {
        guard !didAutoSelect,
              let firstConfigured = Provider.allCases.first(where: { state(for: $0).isConfigured }) else { return }
        didAutoSelect = true
        if !state(for: selected).isConfigured {
            selected = firstConfigured
        }
    }

    func refresh(_ provider: Provider) async {
        guard let credential = await LocalCredentials.credential(for: provider) else {
            states[provider] = .notConfigured
            return
        }
        states[provider] = .loading

        let impl = ProviderFactory.make(provider)
        do {
            states[provider] = .loaded(try await fetch(impl, credential))
        } catch let error as ProviderError where error.isUnauthorized {
            // Token expired/invalid: try one forced refresh + retry, else prompt re-auth.
            if let refreshed = await LocalCredentials.forceRefresh(provider) {
                do {
                    states[provider] = .loaded(try await fetch(impl, refreshed))
                } catch let retry as ProviderError where retry.isUnauthorized {
                    states[provider] = .needsReauth(reauthMessage(provider))
                } catch {
                    states[provider] = .failed(error.localizedDescription)
                }
            } else {
                states[provider] = .needsReauth(reauthMessage(provider))
            }
        } catch {
            states[provider] = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ impl: UsageProviding, _ credential: Credential) async throws -> UsageSnapshot {
        try await impl.fetch(ProviderRequest(credential: credential))
    }

    private func reauthMessage(_ provider: Provider) -> String {
        "Your \(provider.cliName) session has expired or is invalid. Re-authenticate to continue."
    }

    /// Called by the settings UI / re-check actions.
    func reload(_ provider: Provider) {
        Task { await refresh(provider) }
    }

    // MARK: Auto refresh

    func startAutoRefresh() {
        guard !didStart else { return }
        didStart = true
        Task { await refreshAll() }
        scheduleTimer()
    }

    func rescheduleTimer() {
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.refreshAll() }
        }
    }

    /// Peak meter fill across configured providers, for the optional badge.
    var peakFraction: Double? {
        states.values.compactMap { $0.snapshot?.peakFraction }.max()
    }
}
