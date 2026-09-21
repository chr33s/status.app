import WidgetKit
import SwiftUI

/// Quota rings widget — one circular gauge per configured provider, laid out
/// 2 per row (small) or 4 per row (medium), Batteries-widget style.
///
/// Data comes exclusively from the App Group file the app writes after each
/// refresh (see `SharedUsage`); the widget never fetches or touches
/// credentials itself.

struct QuotaEntry: TimelineEntry {
    let date: Date
    /// nil until the app has published usage at least once.
    let payload: SharedUsagePayload?
}

struct QuotaTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry {
        QuotaEntry(date: Date(), payload: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), payload: SharedUsage.read() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: Date(), payload: SharedUsage.read())
        // The app pokes WidgetCenter after every refresh; this is only a
        // fallback re-read in case a poke is missed (e.g. app quit).
        let next = entry.date.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

extension SharedUsagePayload {
    /// Fabricated meters for the widget gallery and placeholder redaction.
    static let placeholder = SharedUsagePayload(
        updatedAt: Date(),
        providers: [
            .init(provider: .codex, snapshot: demo(0.35), needsAttention: false),
            .init(provider: .claude, snapshot: demo(0.62), needsAttention: false),
            .init(provider: .gemini, snapshot: demo(0.12), needsAttention: false),
            .init(provider: .copilot, snapshot: demo(0.80), needsAttention: false),
        ]
    )

    private static func demo(_ fraction: Double) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.sections = [
            UsageSection(title: "Session", fraction: fraction, leading: Format.percentUsed(fraction))
        ]
        return snapshot
    }
}

// MARK: - Views

struct QuotaGridView: View {
    @Environment(\.widgetFamily) private var family
    var entry: QuotaEntry

    private var columns: Int { family == .systemMedium ? 4 : 2 }

    var body: some View {
        Group {
            if let payload = entry.payload, !payload.providers.isEmpty {
                grid(payload.providers)
            } else {
                Text("Open status from the menu bar to load usage.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .widgetURL(URL(string: "status://open"))
    }

    private func grid(_ providers: [SharedProviderUsage]) -> some View {
        // 2×2 on small; medium grows to a second row of 4 when needed.
        let rows = family == .systemMedium ? (providers.count > columns ? 2 : 1) : 2
        let slots = columns * rows
        let shown = Array(providers.prefix(slots))

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
            spacing: 10
        ) {
            ForEach(shown) { usage in
                QuotaRing(usage: usage)
            }
            // Dimmed empty slots keep the grid shape, like the Batteries widget.
            ForEach(0..<max(0, slots - shown.count), id: \.self) { _ in
                EmptySlot()
            }
        }
    }
}

/// One provider's ring: fill = peak meter fraction, brand tint, glyph centre.
struct QuotaRing: View {
    let usage: SharedProviderUsage

    private var fraction: Double {
        min(max(usage.snapshot?.peakFraction ?? 0, 0), 1)
    }

    var body: some View {
        Gauge(value: fraction) {
            Text(usage.provider.displayName)
        } currentValueLabel: {
            if usage.needsAttention {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                // Same template brand glyph the menu's tab strip uses; the
                // imagesets are symlinked into this target's asset catalog.
                Image(usage.provider.assetIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(usage.needsAttention ? .orange : usage.provider.accentColor)
        .accessibilityLabel(usage.provider.displayName)
        .accessibilityValue(
            usage.needsAttention
                ? "Needs re-authentication"
                : "\(Int((fraction * 100).rounded())) percent used"
        )
    }
}

private struct EmptySlot: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 6)
            .padding(3)
    }
}

// MARK: - Widget

struct StatusQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedUsage.widgetKind, provider: QuotaTimelineProvider()) { entry in
            QuotaGridView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("AI Quotas")
        .description("Usage rings for your AI subscriptions.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    StatusQuotaWidget()
} timeline: {
    QuotaEntry(date: .now, payload: .placeholder)
}

#Preview(as: .systemMedium) {
    StatusQuotaWidget()
} timeline: {
    QuotaEntry(date: .now, payload: .placeholder)
}
