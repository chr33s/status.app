import AppKit
import ServiceManagement
import SwiftUI

private enum SettingsTab: String, CaseIterable, Identifiable {
    case providers, telemetry, general
    var id: Self { self }
    var title: String {
        switch self {
        case .providers: return "Providers"
        case .telemetry: return "Telemetry"
        case .general: return "General"
        }
    }
}

struct SettingsView: View {
    @State private var tab: SettingsTab = .providers

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            switch tab {
            case .providers: ProvidersSettingsView()
            case .telemetry: TelemetrySettingsView()
            case .general:   GeneralSettingsView()
            }
        }
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Environment(UsageStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(Provider.allCases) { provider in
                    ProviderStatusCard(provider: provider, state: store.state(for: provider))
                }
                Text("Usage is read from each tool's existing CLI login — no API keys are stored. Status only opens CLI folders you choose. Tokens are refreshed automatically; if one can't be, run the shown login command yourself and choose Re-check.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(12)
        }
        .frame(height: 460)
    }
}

struct ProviderStatusCard: View {
    let provider: Provider
    let state: LoadState
    @Environment(UsageStore.self) private var store

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: provider.systemImage)
                        .font(.title3)
                        .foregroundStyle(provider.accentColor)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.fullName).font(.headline)
                        statusLine
                    }
                    Spacer(minLength: 0)
                }

                switch state {
                case .authorizationRequired(let resource, let lost):
                    FolderAccessPrompt(resource: resource, lost: lost, compact: true)
                case .notConfigured, .needsReauth:
                    ReauthCommandPrompt(provider: provider, compact: true)
                default:
                    HStack {
                        Spacer(minLength: 0)
                        Button("Re-check") { store.reload(provider) }
                            .controlSize(.small)
                    }
                }

                if let resource = provider.externalResource, access.isAuthorized(resource) {
                    FolderGrantRow(resource: resource)
                }
            }
            .padding(6)
        }
    }

    private var access: SecurityScopedAccess { .shared }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .loaded:
            Label("Connected via \(provider.cliName)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .loading:
            Text("Checking \(provider.cliName)…").font(.caption).foregroundStyle(.secondary)
        case .authorizationRequired(let resource, let lost):
            Label(lost ? "Access needs to be granted again" : "Allow Status to access your \(resource.folderName) folder",
                  systemImage: "folder.badge.questionmark")
                .font(.caption).foregroundStyle(.orange)
        case .notConfigured:
            Text("Not signed in. \(provider.cliSignInHint)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .needsReauth:
            Label("Session expired — sign in again", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        case .failed(let message, _):
            Text(message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The folder a provider was granted, with Change… / Remove to replace or
/// withdraw the grant.
struct FolderGrantRow: View {
    let resource: ExternalResource
    @Environment(UsageStore.self) private var store
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Change…") {
                    switch FolderAuthorization.choose(resource) {
                    case .authorized: error = nil; store.reload(resource.provider)
                    case .cancelled: break
                    case .failed(let message): error = message
                    }
                }
                Button("Remove") {
                    SecurityScopedAccess.shared.revoke(resource)
                    store.reload(resource.provider)
                }
            }
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayPath: String {
        guard let url = SecurityScopedAccess.shared.authorizedURL(resource) else { return resource.expectedPath }
        let home = FileManager.default.realHomeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

// MARK: - Telemetry

struct TelemetrySettingsView: View {
    @Environment(TelemetryStore.self) private var telemetry
    @Environment(AppSettings.self) private var settings
    @Environment(UsageStore.self) private var store
    @State private var telemetryError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(telemetry.isRunning ? .green : .red).frame(width: 8, height: 8)
                    Text(telemetry.isRunning
                         ? "Collector on \(telemetry.endpoint)"
                         : "Collector not running")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Toggle("Auto-configure Claude", isOn: Binding(
                    get: { settings.telemetryAutoConfigured },
                    set: { setAutoConfigure($0) }
                ))
                Text("Writes OTLP settings into ~/.claude/settings.json (safely merged). Asks for your .claude folder the first time. Restart Claude Code afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
                if let telemetryError {
                    Text(telemetryError).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Antigravity doesn't export OpenTelemetry.
                ForEach(Provider.allCases.filter { $0 != .antigravity }) { provider in
                    TelemetryProviderRow(provider: provider, endpoint: telemetry.endpoint)
                }
            }
            .padding(12)
        }
        .frame(height: 460)
    }

    /// Enabling needs the `.claude` folder; ask for it if it isn't granted yet
    /// and leave the toggle off if the user declines.
    private func setAutoConfigure(_ on: Bool) {
        telemetryError = nil
        do {
            if on {
                if !SecurityScopedAccess.shared.isAuthorized(.claudeData) {
                    switch FolderAuthorization.choose(.claudeData) {
                    case .authorized: store.reload(.claude)
                    case .cancelled: return
                    case .failed(let message): telemetryError = message; return
                    }
                }
                try OTelSetup.configure(endpoint: telemetry.endpoint)
            } else {
                try OTelSetup.revert()
            }
            settings.telemetryAutoConfigured = on
        } catch {
            telemetryError = error.localizedDescription
            // A revert that can't reach the folder still stops re-applying on launch.
            if !on { settings.telemetryAutoConfigured = false }
        }
    }
}

struct TelemetryProviderRow: View {
    let provider: Provider
    let endpoint: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: provider.systemImage).foregroundStyle(provider.accentColor)
                    Text(provider.fullName).font(.headline)
                    Spacer()
                    if OTelSetup.isAutomatic(provider) {
                        if OTelSetup.isConfigured(provider, endpoint: endpoint) {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Text("Auto").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Manual").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let manual = OTelSetup.manualSnippet(provider, endpoint: endpoint) {
                    Text("Add to \(manual.file):").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(manual.snippet)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(manual.snippet, forType: .string)
                    }
                    .controlSize(.small)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @Environment(UsageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
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
        .scrollContentBackground(.hidden)
        .frame(height: 460)
    }
}
