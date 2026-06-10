import Combine
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

    init() {
        for provider in Provider.allCases {
            states[provider] = Self.isConfigured(provider) ? .loading : .notConfigured
        }
        // Open on the first configured provider, if any.
        if let firstConfigured = Provider.allCases.first(where: { states[$0]?.isConfigured == true }) {
            selected = firstConfigured
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
    }

    func refresh(_ provider: Provider) async {
        guard let credential = await Self.credential(for: provider) else {
            states[provider] = .notConfigured
            return
        }
        states[provider] = .loading

        let impl = ProviderFactory.make(provider)
        do {
            states[provider] = .loaded(try await fetch(provider, impl, credential))
        } catch let error as ProviderError where error.isUnauthorized && provider.authMode == .localCLI {
            // Token likely expired — force a refresh and retry once.
            if let refreshed = await LocalCredentials.forceRefresh(provider) {
                do {
                    states[provider] = .loaded(try await fetch(provider, impl, refreshed))
                } catch {
                    states[provider] = .failed(error.localizedDescription)
                }
            } else {
                states[provider] = .failed(error.localizedDescription)
            }
        } catch {
            states[provider] = .failed(error.localizedDescription)
        }
    }

    private func fetch(_ provider: Provider, _ impl: UsageProviding, _ credential: Credential) async throws -> UsageSnapshot {
        let request = ProviderRequest(
            credential: credential,
            identifier: settings.identifier(for: provider),
            monthlyBudget: settings.budget(for: provider)
        )
        return try await impl.fetch(request)
    }

    // MARK: Credential resolution

    /// Resolves the credential for a provider: a local CLI login for Claude /
    /// Codex (refreshing if expired), or a Keychain-stored API key for
    /// Gemini / Copilot.
    static func credential(for provider: Provider) async -> Credential? {
        switch provider.authMode {
        case .localCLI:
            return await LocalCredentials.freshCredential(provider)
        case .apiKey:
            guard let key = Keychain.get(account: provider.keychainAccount), !key.isEmpty else { return nil }
            return .apiKey(key)
        }
    }

    static func isConfigured(_ provider: Provider) -> Bool {
        switch provider.authMode {
        case .localCLI: return LocalCredentials.exists(provider)
        case .apiKey: return Keychain.hasSecret(account: provider.keychainAccount)
        }
    }

    /// Called by the settings UI after a key is added/removed.
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
