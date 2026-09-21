import Foundation

/// A single labelled usage meter, e.g. "Session", "Weekly", "Spend".
/// Codable so snapshots can be handed to the widget via the App Group.
struct UsageSection: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var title: String
    /// 0...1 fill for the progress bar. `nil` hides the bar.
    var fraction: Double?
    /// Left caption, e.g. "2% used" or "This month: $ 12.00".
    var leading: String
    /// Right caption, e.g. "Resets in 3h 53m".
    var trailing: String?
    /// Optional muted note under the bar.
    var note: String?
}

/// Everything needed to render one provider's detail panel.
struct UsageSnapshot: Sendable, Codable {
    var planName: String?
    var sections: [UsageSection] = []
    /// Free-form note shown when there are no meters.
    var note: String?
    var fetchedAt: Date = Date()

    /// Largest meter fill across sections — used for the optional menu-bar badge.
    var peakFraction: Double? {
        sections.compactMap(\.fraction).max()
    }

    /// A snapshot that shows only a plan name and an informational note.
    static func notice(plan: String?, _ note: String) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.planName = plan
        snapshot.note = note
        return snapshot
    }
}
