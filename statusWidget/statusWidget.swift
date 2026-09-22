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
            .init(provider: .codex, snapshot: demo(session: 0.35, weekly: 0.55), needsAttention: false),
            .init(provider: .claude, snapshot: demo(session: 0.62, weekly: 0.40), needsAttention: false),
            .init(provider: .antigravity, snapshot: demo(session: 0.12, weekly: 0.30), needsAttention: false),
            .init(provider: .copilot, snapshot: demo(session: 0.80, weekly: 0.65), needsAttention: false),
        ]
    )

    private static func demo(session: Double, weekly: Double) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.sections = [
            UsageSection(title: "Session", fraction: session, leading: Format.percentUsed(session)),
            UsageSection(title: "Weekly", fraction: weekly, leading: Format.percentUsed(weekly)),
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

/// One provider's meters as concentric rings — outer = weekly quota, inner =
/// session quota — with the brand glyph in the centre. Providers reporting a
/// single meter (or none) fall back to one ring.
struct QuotaRing: View {
    let usage: SharedProviderUsage

    /// First weekly meter — the outer ring.
    private var weekly: Double? {
        fraction { $0.localizedCaseInsensitiveContains("week") }
    }

    /// First non-weekly meter (Session, Rate limit, …) — the inner ring.
    private var session: Double? {
        fraction { !$0.localizedCaseInsensitiveContains("week") }
    }

    private func fraction(where titleMatches: (String) -> Bool) -> Double? {
        usage.snapshot?.sections
            .first { titleMatches($0.title) && $0.fraction != nil }?
            .fraction
            .map { min(max($0, 0), 1) }
    }

    var body: some View {
        ZStack {
            Group {
                if let session, let weekly {
                    Ring(fraction: weekly, lineWidth: 6)
                    Ring(fraction: session, lineWidth: 3.5)
                        .padding(9)
                } else {
                    Ring(fraction: weekly ?? session ?? 0, lineWidth: 6)
                }
            }
            // Same 6pt stroke inset 3pt as `EmptySlot`, i.e. the old gauge size.
            .padding(3)
            .foregroundStyle(usage.needsAttention ? Color.orange : usage.provider.accentColor)

            if usage.needsAttention {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                // Same template brand glyph the menu's tab strip uses; the
                // imagesets are symlinked into this target's asset catalog.
                Image(usage.provider.assetIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(usage.provider.displayName)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if usage.needsAttention { return "Needs re-authentication" }
        var parts: [String] = []
        if let session { parts.append("session \(Int((session * 100).rounded())) percent used") }
        if let weekly { parts.append("weekly \(Int((weekly * 100).rounded())) percent used") }
        return parts.isEmpty ? "No usage data" : parts.joined(separator: ", ")
    }
}

/// A capacity ring: dimmed full-circle track under a solid fill arc that
/// starts at 12 o'clock. Both derive their colour from the foreground style.
private struct Ring: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
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
