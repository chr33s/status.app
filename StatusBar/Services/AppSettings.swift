import Foundation
import ServiceManagement
import SwiftUI

/// Non-secret preferences (identifiers, budgets, refresh cadence, launch-at-login).
/// Secrets live in the Keychain, never here.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let refresh = "refreshMinutes"
        static let identifiers = "identifiers"
        static let budgets = "budgets"
        static let showBadge = "showMenuBarBadge"
    }

    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refresh) }
    }
    @Published var showMenuBarBadge: Bool {
        didSet { defaults.set(showMenuBarBadge, forKey: Key.showBadge) }
    }
    @Published private var identifiers: [String: String] {
        didSet { defaults.set(identifiers, forKey: Key.identifiers) }
    }
    @Published private var budgets: [String: Double] {
        didSet { defaults.set(budgets, forKey: Key.budgets) }
    }

    private init() {
        refreshMinutes = defaults.object(forKey: Key.refresh) as? Int ?? 30
        showMenuBarBadge = defaults.object(forKey: Key.showBadge) as? Bool ?? false
        identifiers = defaults.dictionary(forKey: Key.identifiers) as? [String: String] ?? [:]
        budgets = defaults.dictionary(forKey: Key.budgets) as? [String: Double] ?? [:]
    }

    // MARK: Per-provider config

    func identifier(for provider: Provider) -> String {
        identifiers[provider.rawValue] ?? ""
    }

    func setIdentifier(_ value: String, for provider: Provider) {
        identifiers[provider.rawValue] = value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func budget(for provider: Provider) -> Double? {
        budgets[provider.rawValue]
    }

    func setBudget(_ value: Double?, for provider: Provider) {
        if let value, value > 0 {
            budgets[provider.rawValue] = value
        } else {
            budgets.removeValue(forKey: provider.rawValue)
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Launch-at-login toggle failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }
}
