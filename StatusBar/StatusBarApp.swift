import SwiftUI

@main
struct StatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(store)
                .environmentObject(settings)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
                .environmentObject(settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
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
