import SwiftUI

@main
struct StatusApp: App {
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

