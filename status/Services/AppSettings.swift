import Foundation
import ServiceManagement

/// Non-secret preferences (refresh cadence, badge, launch-at-login, enabled providers).
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults
    private enum Key {
        static let refresh = "refreshMinutes"
        static let showBadge = "showMenuBarBadge"
        static let telemetryAuto = "telemetryAutoConfigured"
        static let disabledProviders = "disabledProviders"
    }

    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refresh) }
    }
    var showMenuBarBadge: Bool {
        didSet { defaults.set(showMenuBarBadge, forKey: Key.showBadge) }
    }
    /// Whether the app auto-configures Claude telemetry on launch.
    var telemetryAutoConfigured: Bool {
        didSet { defaults.set(telemetryAutoConfigured, forKey: Key.telemetryAuto) }
    }
    /// Providers the user has explicitly turned off in Settings.
    var disabledProviders: Set<Provider> {
        didSet {
            defaults.set(disabledProviders.map(\.rawValue).sorted(), forKey: Key.disabledProviders)
        }
    }

    /// Bumped manually so views observing `launchAtLogin` re-render after a
    /// successful toggle (SMAppService has no publisher).
    private var launchAtLoginVersion = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshMinutes = defaults.object(forKey: Key.refresh) as? Int ?? 30
        showMenuBarBadge = defaults.object(forKey: Key.showBadge) as? Bool ?? false
        telemetryAutoConfigured = defaults.object(forKey: Key.telemetryAuto) as? Bool ?? false
        let rawDisabled = defaults.stringArray(forKey: Key.disabledProviders) ?? []
        disabledProviders = Set(rawDisabled.compactMap(Provider.init(rawValue:)))
    }

    // MARK: Enabled providers

    var enabledProviders: [Provider] {
        Provider.allCases.filter { !disabledProviders.contains($0) }
    }

    func isEnabled(_ provider: Provider) -> Bool {
        !disabledProviders.contains(provider)
    }

    func setEnabled(_ enabled: Bool, for provider: Provider) {
        if enabled {
            disabledProviders.remove(provider)
        } else {
            disabledProviders.insert(provider)
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get {
            _ = launchAtLoginVersion
            return SMAppService.mainApp.status == .enabled
        }
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
            launchAtLoginVersion &+= 1
        }
    }
}
