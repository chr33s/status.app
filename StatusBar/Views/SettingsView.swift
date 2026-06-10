import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "key.fill") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Provider.allCases) { provider in
                    ProviderKeyCard(provider: provider)
                }
                Text("Keys are stored in your macOS Keychain and used read-only. They never leave your Mac except in requests to the provider's own API.")
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

struct ProviderKeyCard: View {
    let provider: Provider
    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var settings: AppSettings

    @State private var key: String = ""
    @State private var identifier: String = ""
    @State private var budgetText: String = ""
    @State private var saved = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: provider.systemImage)
                        .foregroundStyle(provider.accentColor)
                    Text(provider.fullName).font(.headline)
                    Spacer()
                    if Keychain.hasSecret(account: provider.keychainAccount) {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Text(provider.keyHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(provider.identifierLabel, text: $identifier)
                    .textFieldStyle(.roundedBorder)

                TextField("Monthly budget in USD (optional)", text: $budgetText)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(provider.accentColor)
                    Button("Remove") { remove() }
                        .disabled(!Keychain.hasSecret(account: provider.keychainAccount))
                    Spacer()
                    if saved {
                        Text("Saved").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
        .onAppear(perform: load)
    }

    private func load() {
        key = Keychain.get(account: provider.keychainAccount) ?? ""
        identifier = settings.identifier(for: provider)
        if let budget = settings.budget(for: provider) {
            budgetText = String(format: "%g", budget)
        }
    }

    private func save() {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmedKey.isEmpty {
                try Keychain.remove(account: provider.keychainAccount)
            } else {
                try Keychain.set(trimmedKey, account: provider.keychainAccount)
            }
        } catch {
            NSLog("Keychain save failed: \(error.localizedDescription)")
        }
        settings.setIdentifier(identifier, for: provider)
        settings.setBudget(Double(budgetText.replacingOccurrences(of: ",", with: ".")), for: provider)
        store.reload(provider)
        flashSaved()
    }

    private func remove() {
        try? Keychain.remove(account: provider.keychainAccount)
        key = ""
        store.reload(provider)
        flashSaved()
    }

    private func flashSaved() {
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saved = false }
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
