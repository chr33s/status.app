import Foundation

enum Format {
    /// "$ 254.24"
    static func currency(_ amount: Double) -> String {
        String(format: "$ %.2f", amount)
    }

    /// "15K", "218M", "942"
    static func tokens(_ count: Double) -> String {
        let n = abs(count)
        switch n {
        case 1_000_000_000...:
            return trim(count / 1_000_000_000) + "B"
        case 1_000_000...:
            return trim(count / 1_000_000) + "M"
        case 1_000...:
            return trim(count / 1_000) + "K"
        default:
            return String(Int(count.rounded()))
        }
    }

    /// "2% used"
    static func percentUsed(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) % used"
    }

    /// "Resets in 3h 53m" / "Resets in 3d 20h"
    static func resetCountdown(to date: Date, now: Date = Date()) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if days > 0 { return "Resets in \(days)d \(hours)h" }
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    /// "Updated just now" / "Updated 5m ago"
    static func updated(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "Updated just now" }
        if seconds < 3_600 { return "Updated \(seconds / 60)m ago" }
        if seconds < 86_400 { return "Updated \(seconds / 3_600)h ago" }
        return "Updated \(seconds / 86_400)d ago"
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

extension Date {
    /// 00:00 on the first day of the current month, in the user's calendar.
    static var startOfMonth: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: Date())
        return calendar.date(from: components) ?? Date()
    }

    static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    static var thirtyDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    }
}
