import Combine
import Foundation
import ServiceManagement

/// Non-secret preferences (refresh cadence, badge, launch-at-login).
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let refresh = "refreshMinutes"
        static let showBadge = "showMenuBarBadge"
    }

    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refresh) }
    }
    @Published var showMenuBarBadge: Bool {
        didSet { defaults.set(showMenuBarBadge, forKey: Key.showBadge) }
    }

    private init() {
        refreshMinutes = defaults.object(forKey: Key.refresh) as? Int ?? 30
        showMenuBarBadge = defaults.object(forKey: Key.showBadge) as? Bool ?? false
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
