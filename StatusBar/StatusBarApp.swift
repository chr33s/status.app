import SwiftUI

@main
struct StatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var settings = AppSettings.shared
    @StateObject private var telemetry = TelemetryStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(telemetry)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(telemetry)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(telemetry)
        }
    }
}

/// Keeps the app out of the Dock / app switcher (belt-and-suspenders alongside
/// `LSUIElement`) and kicks off the first refresh once launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
