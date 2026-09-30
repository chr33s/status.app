import Foundation

enum Format {
    /// "$ 254.24"
    static func currency(_ amount: Double) -> String {
        String(format: "$ %.2f", amount)
    }

    /// "2% used"
    static func percentUsed(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "Usage unavailable" }
        return String(format: "%.0f%% used", (min(max(fraction, 0), 1) * 100).rounded())
    }

    /// "942" / "15K" / "218M"
    static func compact(_ count: Double) -> String {
        guard count.isFinite else { return "—" }
        switch abs(count) {
        case 1_000_000...: return trim(count / 1_000_000) + "M"
        case 1_000...: return trim(count / 1_000) + "K"
        default: return String(format: "%.0f", count.rounded())
        }
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }

    /// "Resets in 3h 53m" / "Resets in 3d 20h"
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        guard let count = Int(exactly: seconds.rounded(.down)) else { return "Reset time unavailable" }
        let days = count / 86_400
        let hours = (count % 86_400) / 3_600
        let minutes = (count % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    /// "Updated just now" / "Updated 5m ago"
    static func updated(_ date: Date, now: Date = Date()) -> String {
        guard let seconds = Int(exactly: now.timeIntervalSince(date).rounded(.towardZero)) else { return "Update time unavailable" }
        if seconds < 45 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }
}
