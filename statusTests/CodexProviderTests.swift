import Foundation
import Testing
@testable import status

struct CodexProviderTests {
    /// A `wham/usage` body: a 5-hour primary window and a weekly secondary.
    private static let usage: [String: Any] = [
        "plan_type": "pro",
        "rate_limit": [
            "allowed": true,
            "primary_window": [
                "used_percent": 12,
                "limit_window_seconds": 5 * 3_600,
                "reset_after_seconds": 2 * 3_600 + 30 * 60,
                "reset_at": Int(testResetEpoch) ?? 0,
            ],
            "secondary_window": [
                "used_percent": 40,
                "limit_window_seconds": 7 * 24 * 3_600,
                "reset_after_seconds": 3 * 24 * 3_600,
            ],
        ],
    ]

    private static func provider(_ response: Result<HTTPResult, Error>) -> CodexProvider {
        CodexProvider(transport: { url, headers in
            #expect(url == CodexProvider.endpoint)
            #expect(headers["Authorization"] == "Bearer token")
            #expect(headers["chatgpt-account-id"] == "account")
            return try response.get()
        }, now: { testNow })
    }

    @Test func windowSectionMapsPercentAndReset() throws {
        let window = JSON((Self.usage["rate_limit"] as? [String: Any])?["primary_window"])
        let section = try #require(SessionUsage.windowSection(window, fallbackTitle: "Weekly", now: testNow))
        #expect(section.title == "Session")
        #expect(section.fraction == 0.12)
        #expect(section.leading == "12% used")
        #expect(section.trailing == "Resets in 2h 30m")
    }

    @Test func windowSectionFallsBackToResetAfterSeconds() throws {
        let section = try #require(SessionUsage.windowSection(
            JSON(["used_percent": 5, "reset_after_seconds": 90 * 60]), fallbackTitle: "Weekly", now: testNow
        ))
        #expect(section.title == "Weekly")
        #expect(section.trailing == "Resets in 1h 30m")
    }

    @Test func sectionsUseWindowDurationWhenOrderIsInverted() throws {
        let sections = CodexProvider.sections(in: JSON(["rate_limit": [
            "primary_window": ["used_percent": 60, "limit_window_seconds": 7 * 24 * 3_600],
            "secondary_window": ["used_percent": 20, "limit_window_seconds": 5 * 3_600],
        ]]), now: testNow)

        #expect(sections.map(\.title) == ["Session", "Weekly"])
        #expect(try #require(sections.first).fraction == 0.20)
        #expect(try #require(sections.last).fraction == 0.60)
    }

    /// Single-window plans report `secondary_window: null`, or a zero-length
    /// placeholder window; neither may become a bogus 0% meter.
    @Test(arguments: ["null", "zero-length"])
    func absentSecondaryWindowIsSkipped(shape: String) {
        let secondary: Any = shape == "null"
            ? NSNull()
            : ["used_percent": 0, "limit_window_seconds": 0, "reset_after_seconds": 0]
        let sections = CodexProvider.sections(in: JSON(["rate_limit": [
            "primary_window": ["used_percent": 3, "limit_window_seconds": 7 * 24 * 3_600],
            "secondary_window": secondary,
        ]]), now: testNow)
        #expect(sections.map(\.title) == ["Weekly"])
    }

    @Test func windowSectionIsClamped() {
        let section = SessionUsage.windowSection(JSON(["used_percent": 250]), fallbackTitle: "Weekly")
        #expect(section?.fraction == 1)
    }

    @Test func missingPercentReturnsNil() {
        #expect(SessionUsage.windowSection(JSON([:]), fallbackTitle: "Session") == nil)
        #expect(SessionUsage.windowSection(JSON(nil), fallbackTitle: "Session") == nil)
    }

    @Test func fetchParsesUsage() async throws {
        let snapshot = try await Self.provider(.success(.stub(Self.usage))).fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.map(\.title) == ["Session", "Weekly"])
        #expect(snapshot.note == nil)
    }

    @Test(arguments: [401, 403])
    func unauthorizedStatusThrows(status: Int) async {
        await #expect {
            _ = try await Self.provider(.failure(ProviderError.http(status: status, body: ""))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func transportFailurePropagatesToPreserveStaleUsage() async {
        await #expect(throws: URLError.self) {
            _ = try await Self.provider(.failure(URLError(.timedOut))).fetch(.oauth)
        }
    }

    @Test func noWindowsYieldsNote() async throws {
        let snapshot = try await Self.provider(.success(.stub(["plan_type": "free"]))).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }

    @Test func apiKeyDoesNotProbe() async throws {
        let provider = CodexProvider(transport: { url, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        let snapshot = try await provider.fetch(.apiKey)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }
}
