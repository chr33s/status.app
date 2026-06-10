import Foundation

/// A single labelled usage meter, e.g. "Session", "Weekly", "Extra usage".
struct UsageSection: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    /// 0...1 fill for the progress bar. `nil` hides the bar.
    var fraction: Double?
    /// Left caption, e.g. "2% used" or "This month: $ 0.00 / $ 2000.00".
    var leading: String
    /// Right caption, e.g. "Resets in 3h 53m" or "0% used".
    var trailing: String?
    /// Optional muted note under the bar, e.g. "Pace: Behind (-42%)".
    var note: String?
}

/// The cost summary block shown near the bottom of a provider's detail.
struct CostInfo: Hashable, Sendable {
    var todayAmount: Double?
    var todayTokens: Double?
    var last30Amount: Double?
    var last30Tokens: Double?
}

/// Everything needed to render one provider's detail panel.
struct UsageSnapshot: Sendable {
    var planName: String?
    var sections: [UsageSection] = []
    var cost: CostInfo?
    /// Free-form note shown when there are no meters (e.g. Gemini).
    var note: String?
    var fetchedAt: Date = Date()

    /// Largest meter fill across sections — used for the optional menu-bar badge.
    var peakFraction: Double? {
        sections.compactMap(\.fraction).max()
    }
}
