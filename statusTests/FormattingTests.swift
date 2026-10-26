import Foundation
import Testing
@testable import status

struct FormattingTests {
    @Test(arguments: ["NaN", "Infinity", "-Infinity", "1e999"])
    func nonfiniteJSONNumbersAreIgnored(_ raw: String) {
        #expect(JSON(raw).double == nil)
        #expect(SessionUsage.resetDate(from: raw) == nil)
        #expect(SessionUsage.windowSection(JSON(["used_percent": raw]), fallbackTitle: "Session") == nil)
        #expect(ClaudeProvider.sections(from: .stub(headers: [
            "anthropic-ratelimit-unified-5h-utilization": raw,
        ])).isEmpty)
    }

    @Test func largeAndNonfiniteCountsDoNotTrap() {
        #expect(Format.percentUsed(0.125) == "13% used")
        #expect(Format.compact(.infinity) == "—")
        #expect(Format.compact(.nan) == "—")
        #expect(!Format.compact(1e30).isEmpty)
        #expect(Format.percentUsed(.nan) == "Usage unavailable")
        #expect(Format.resetCountdown(to: Date(timeIntervalSince1970: 1e30), now: testNow) == "Reset time unavailable")
    }

    @Test func fractionalISOAndRelativeResetUseTheSuppliedClock() throws {
        let date = try #require(SessionUsage.resetDate(from: "2026-09-30T12:00:00.123Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_790_769_600.123) < 0.001)
        let section = SessionUsage.utilizationSection(title: "Session", utilization: 0.5, reset: "9000", now: testNow)
        #expect(section?.trailing == "Resets in 2h 30m")
    }

    @Test(arguments: [("12ms", 0.012), ("30s", 30), ("6m0s", 360), ("1h2m3.5s", 3_723.5)])
    func goStyleDurationsParse(raw: String, seconds: Double) {
        #expect(SessionUsage.duration(from: raw) == seconds)
    }

    @Test(arguments: ["", "abc", "5x", "1h2"])
    func malformedDurationsAreRejected(raw: String) {
        #expect(SessionUsage.duration(from: raw) == nil)
    }
}
