import SwiftUI

/// The scrolling detail panel for the selected provider: header, meters, cost.
struct ProviderDetailView: View {
    let provider: Provider
    let state: LoadState
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .notConfigured:
                reauthPrompt(
                    subtitle: "Not signed in",
                    message: "No \(provider.cliName) login found. \(provider.cliSignInHint)",
                    buttonTitle: "Sign in with \(provider.cliName)"
                )
            case .loading:
                header(plan: nil, subtitle: "Updating…")
                ProgressView().controlSize(.small)
            case .needsReauth(let message):
                reauthPrompt(
                    subtitle: "Session expired",
                    message: message,
                    buttonTitle: "Re-authenticate"
                )
            case .failed(let message):
                header(plan: nil, subtitle: "Couldn't update")
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded(let snapshot):
                loaded(snapshot)
            }

            telemetryBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    /// Live usage streamed from the CLI over OpenTelemetry, shown under whatever
    /// the probe returned.
    @ViewBuilder
    private var telemetryBlock: some View {
        let usage = telemetry.usage(for: provider)
        if usage.hasData {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Telemetry").font(.headline)
                if usage.totalTokens > 0 {
                    telemetryRow("Tokens", tokenSummary(usage))
                }
                if usage.cost > 0 {
                    telemetryRow("Cost", Format.currency(usage.cost))
                }
                if usage.requests > 0 {
                    telemetryRow("Requests", String(Int(usage.requests)))
                }
                Text("Live from \(provider.cliName) since launch")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func telemetryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
        }
        .font(.callout)
    }

    private func tokenSummary(_ usage: TelemetryUsage) -> String {
        var parts = ["\(Format.compact(usage.inputTokens)) in", "\(Format.compact(usage.outputTokens)) out"]
        if usage.cacheTokens > 0 { parts.append("\(Format.compact(usage.cacheTokens)) cache") }
        return "\(Format.compact(usage.totalTokens)) · " + parts.joined(separator: " · ")
    }

    // MARK: States

    private func reauthPrompt(subtitle: String, message: String, buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(plan: nil, subtitle: subtitle)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Reauth.start(provider)
            } label: {
                Label(buttonTitle, systemImage: "person.badge.key")
            }
            .buttonStyle(.borderedProminent)
            .tint(provider.accentColor)
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
