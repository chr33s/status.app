import SwiftUI

/// The status-item shown in the system menu bar. Starts the refresh schedule the
/// first time it appears, and optionally shows the peak usage percentage.
struct MenuBarLabel: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        Group {
            if settings.showMenuBarBadge, let peak = store.peakFraction {
                Label("\(Int((peak * 100).rounded()))%", systemImage: "chart.bar.fill")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .task {
            store.startAutoRefresh()
            telemetry.start()
            if settings.telemetryAutoConfigured {
                let endpoint = telemetry.endpoint
                Task.detached { OTelSetup.configure(endpoint: endpoint) }
            }
        }
    }
}
