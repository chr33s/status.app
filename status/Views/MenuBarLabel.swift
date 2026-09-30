import SwiftUI

/// The status-item shown in the system menu bar. Starts the refresh schedule the
/// first time it appears, and optionally shows the peak usage percentage.
struct MenuBarLabel: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(TelemetryStore.self) private var telemetry

    var body: some View {
        Group {
            if let peak = store.peakFraction {
                if settings.showMenuBarBadge {
                    Label {
                        Text("\(Int((peak * 100).rounded()))%")
                    } icon: {
                        Image(nsImage: MenuBarGauge.image(usage: peak))
                    }
                    .labelStyle(.titleAndIcon)
                } else {
                    Image(nsImage: MenuBarGauge.image(usage: peak))
                }
            } else {
                Image("MenuBarIcon")
            }
        }
        .task {
            guard ProcessInfo.processInfo.environment["STATUS_TESTING"] != "1",
                  NSClassFromString("XCTestCase") == nil else { return }
            store.startAutoRefresh()
            telemetry.start()
            if settings.telemetryAutoConfigured {
                let endpoint = telemetry.endpoint
                // Silently skipped if the .claude folder grant is missing.
                Task.detached { try? OTelSetup.configure(endpoint: endpoint) }
            }
        }
    }
}
