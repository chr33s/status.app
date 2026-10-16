import Foundation

/// Shared helpers for building subscription "session limit" meters from the
/// data returned by the Claude Code / Codex back-ends.
enum SessionUsage {
    /// Interprets a reset value that may be a unix timestamp (seconds) or an
    /// RFC3339 string, returning the absolute reset date.
    static func resetDate(from raw: String?, now: Date = Date()) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let epoch = Double(raw) {
            guard epoch.isFinite else { return nil }
            // Heuristic: values far in the future are absolute epochs; small
            // values are "seconds from now".
            return epoch > 10_000_000_000
                ? Date(timeIntervalSince1970: epoch / 1000)
                : (epoch > 1_000_000_000
                    ? Date(timeIntervalSince1970: epoch)
                    : now.addingTimeInterval(epoch))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// Builds a meter from a rate-limit "window" object of the shape returned
    /// by Codex's `wham/usage`:
    /// `{ used_percent, limit_window_seconds, reset_after_seconds, reset_at }`.
    /// The title is Session for windows under a day and Weekly otherwise;
    /// `fallbackTitle` applies when the window length is absent. A zero-length
    /// window is the backend's "no such limit" placeholder and yields nil.
    static func windowSection(_ json: JSON, fallbackTitle: String, now: Date = Date()) -> UsageSection? {
        guard let percent = json["used_percent"].double else { return nil }
        let seconds = json["limit_window_seconds"].double
        if let seconds, seconds <= 0 { return nil }
        let fraction = min(max(percent / 100, 0), 1)
        var section = UsageSection(
            title: seconds.map { $0 < 24 * 3_600 ? "Session" : "Weekly" } ?? fallbackTitle,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let date = resetDate(from: json["reset_at"].string, now: now)
            ?? json["reset_after_seconds"].double.map({ now.addingTimeInterval($0) }) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }

    /// Builds a meter from `limit` / `remaining` / `reset` values (Anthropic's
    /// legacy rate-limit headers, still used for API-key callers).
    static func limitSection(title: String, limit: Double?, remaining: Double?, reset: String?, now: Date = Date()) -> UsageSection? {
        guard let limit, limit > 0, let remaining else { return nil }
        let used = max(0, limit - remaining)
        let fraction = min(max(used / limit, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let date = resetDate(from: reset, now: now) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }

    /// Builds a meter from a single `utilization` fraction (0-1) and reset
    /// time — Anthropic's current Claude Code unified rate-limit headers
    /// (`anthropic-ratelimit-unified-{5h,7d}-utilization`).
    static func utilizationSection(title: String, utilization: Double?, reset: String?, now: Date = Date()) -> UsageSection? {
        guard let utilization, utilization.isFinite else { return nil }
        let fraction = min(max(utilization, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let date = resetDate(from: reset, now: now) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }
}
