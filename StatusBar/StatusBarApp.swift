import SwiftUI

@main
struct StatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = UsageStore()
    @State private var settings = AppSettings.shared
    @State private var telemetry = TelemetryStore()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
                .environment(settings)
                .environment(telemetry)
        } label: {
            MenuBarLabel()
                .environment(store)
                .environment(settings)
                .environment(telemetry)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app out of the Dock / app switcher (belt-and-suspenders alongside
/// `LSUIElement`) and kicks off the first refresh once launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
