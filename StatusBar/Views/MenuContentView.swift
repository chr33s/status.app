import SwiftUI

/// Root popover content: tab strip, provider detail, and the action menu.
struct MenuContentView: View {
    @EnvironmentObject private var store: UsageStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ProviderTabBar(selected: $store.selected, store: store)

            Divider()

            ScrollView {
                ProviderDetailView(
                    provider: store.selected,
                    state: store.state(for: store.selected)
                )
            }
            .frame(height: 360)

            Divider()
            actionMenu
            Divider()
            footer
        }
        .frame(width: 320)
    }

    // MARK: Action menu

    private var actionMenu: some View {
        VStack(spacing: 0) {
            MenuRow(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await store.refreshAll() }
            }
            MenuRow(title: "Usage Dashboard", systemImage: "chart.bar.doc.horizontal") {
                openURL(store.selected.dashboardURL)
            }
            MenuRow(title: "Status Page", systemImage: "waveform.path.ecg") {
                openURL(store.selected.statusURL)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            SettingsLink {
                MenuRowLabel(title: "Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            MenuRow(title: "Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A clickable, hover-highlighting row used throughout the menu.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

struct MenuRowLabel: View {
    let title: String
    let systemImage: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onHover { hovering = $0 }
    }
}
