import Foundation

/// Shared helpers for building subscription "session limit" meters from the
/// data returned by the Claude Code / Codex back-ends.
enum SessionUsage {
    /// Interprets a reset value that may be a unix timestamp (seconds) or an
    /// RFC3339 string, returning the absolute reset date.
    static func resetDate(from raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let epoch = Double(raw) {
            // Heuristic: values far in the future are absolute epochs; small
            // values are "seconds from now".
            return epoch > 10_000_000_000
                ? Date(timeIntervalSince1970: epoch / 1000)
                : (epoch > 1_000_000_000
                    ? Date(timeIntervalSince1970: epoch)
                    : Date().addingTimeInterval(epoch))
        }
        return ISO8601DateFormatter().date(from: raw)
    }

    /// Builds a meter from a "window" object of the shape returned by Codex:
    /// `{ used_percent, window_minutes, resets_in_seconds }`.
    static func windowSection(title: String, _ json: JSON) -> UsageSection? {
        guard let percent = json["used_percent"].double else { return nil }
        let fraction = min(max(percent / 100, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let resets = json["resets_in_seconds"].double {
            section.trailing = Format.resetCountdown(to: Date().addingTimeInterval(resets))
        }
        return section
    }

    /// Builds a meter from `limit` / `remaining` / `reset` values (Anthropic
    /// rate-limit headers).
    static func limitSection(title: String, limit: Double?, remaining: Double?, reset: String?) -> UsageSection? {
        guard let limit, limit > 0, let remaining else { return nil }
        let used = max(0, limit - remaining)
        let fraction = min(max(used / limit, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let date = resetDate(from: reset) {
            section.trailing = Format.resetCountdown(to: date)
        }
        return section
    }
}
