import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "person.badge.key") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(Provider.allCases) { provider in
                    ProviderStatusCard(provider: provider, state: store.state(for: provider))
                }
                Text("Usage is read from each tool's existing CLI login — no API keys are stored. Tokens are refreshed automatically; if one can't be refreshed you'll be prompted to re-authenticate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .frame(height: 460)
    }
}

struct ProviderStatusCard: View {
    let provider: Provider
    let state: LoadState
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: provider.systemImage)
                    .font(.title3)
                    .foregroundStyle(provider.accentColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.fullName).font(.headline)
                    statusLine
                }

                Spacer()

                VStack(spacing: 6) {
                    if state.needsAttention {
                        Button("Re-authenticate") { Reauth.start(provider) }
                            .buttonStyle(.borderedProminent)
                            .tint(provider.accentColor)
                    }
                    Button("Re-check") { store.reload(provider) }
                        .controlSize(.small)
                }
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .loaded:
            Label("Connected via \(provider.cliName)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .loading:
            Text("Checking \(provider.cliName)…").font(.caption).foregroundStyle(.secondary)
        case .notConfigured:
            Text("Not signed in. \(provider.cliSignInHint)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .needsReauth:
            Label("Session expired — re-authenticate", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Refresh every", selection: $settings.refreshMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("3 hours").tag(180)
                }
                .onChange(of: settings.refreshMinutes) { _, _ in store.rescheduleTimer() }

                Toggle("Show usage % in the menu bar", isOn: $settings.showMenuBarBadge)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
            }

            Section {
                Button("Refresh now") { Task { await store.refreshAll() } }
                if let last = store.lastRefresh {
                    Text(Format.updated(last))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}
