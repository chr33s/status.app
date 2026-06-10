import SwiftUI

/// The scrolling detail panel for the selected provider: header, meters, cost.
struct ProviderDetailView: View {
    let provider: Provider
    let state: LoadState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .notConfigured:
                notConfigured
            case .loading:
                header(plan: nil, subtitle: "Updating…")
                ProgressView().controlSize(.small)
            case .failed(let message):
                header(plan: nil, subtitle: "Couldn't update")
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let snapshot):
                loaded(snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    // MARK: States

    private var notConfigured: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(plan: nil, subtitle: "Not configured")
            switch provider.authMode {
            case .localCLI:
                Text("No \(provider.cliName ?? "CLI") login found. \(provider.cliSignInHint)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .apiKey:
                Text("Add a read-only \(provider.vendor) API key to start tracking \(provider.fullName) usage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink {
                    Label("Add API key…", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.accentColor)
            }
        }
    }

    @ViewBuilder
    private func loaded(_ snapshot: UsageSnapshot) -> some View {
        header(plan: snapshot.planName, subtitle: Format.updated(snapshot.fetchedAt))

        if let note = snapshot.note {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(snapshot.sections) { section in
            Divider()
            SectionView(section: section, tint: provider.accentColor)
        }

        if let cost = snapshot.cost, cost.hasData {
            Divider()
            CostView(cost: cost, dashboardURL: provider.dashboardURL)
        }
    }

    // MARK: Header

    private func header(plan: String?, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.fullName)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let plan, !plan.isEmpty {
                Text(plan)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The "Cost" block: today + last 30 days, with a link to the dashboard.
struct CostView: View {
    let cost: CostInfo
    let dashboardURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cost")
                    .font(.headline)
                Spacer()
                Link(destination: dashboardURL) {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let line = line(prefix: "Today", amount: cost.todayAmount, tokens: cost.todayTokens) {
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            if let line = line(prefix: "Last 30 days", amount: cost.last30Amount, tokens: cost.last30Tokens) {
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func line(prefix: String, amount: Double?, tokens: Double?) -> String? {
        guard amount != nil || tokens != nil else { return nil }
        var parts: [String] = []
        if let amount { parts.append(Format.currency(amount)) }
        if let tokens, tokens > 0 { parts.append("\(Format.tokens(tokens)) tokens") }
        return "\(prefix): " + parts.joined(separator: " · ")
    }
}

extension CostInfo {
    var hasData: Bool {
        todayAmount != nil || last30Amount != nil || todayTokens != nil || last30Tokens != nil
    }
}
