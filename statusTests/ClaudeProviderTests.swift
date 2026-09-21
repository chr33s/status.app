import Foundation
import Testing
@testable import status

struct ClaudeProviderTests {
    private static func provider(_ response: Result<HTTPResult, Error>) -> ClaudeProvider {
        ClaudeProvider(transport: { url, headers, body in
            #expect(url == ClaudeProvider.endpoint)
            #expect(headers["Authorization"] == "Bearer token")
            #expect(headers["anthropic-beta"]?.contains("oauth-2025-04-20") == true)
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["max_tokens"] as? Int == 1)
            return try response.get()
        }, now: { testNow })
    }

    @Test func unifiedHeadersMapToSessionAndWeekly() {
        let sections = ClaudeProvider.sections(from: .stub(headers: [
            "anthropic-ratelimit-unified-5h-utilization": "0.25",
            "anthropic-ratelimit-unified-5h-reset": testResetEpoch,
            "anthropic-ratelimit-unified-7d-utilization": "0.6",
        ]), now: testNow)
        #expect(sections.map(\.title) == ["Session", "Weekly"])
        #expect(sections[0].fraction == 0.25)
        #expect(sections[0].leading == "25% used")
        #expect(sections[0].trailing == "Resets in 2h 30m")
        #expect(sections[1].fraction == 0.6)
        #expect(sections[1].trailing == nil)
    }

    @Test func utilizationIsClamped() {
        let sections = ClaudeProvider.sections(from: .stub(headers: [
            "anthropic-ratelimit-unified-5h-utilization": "1.4",
        ]), now: testNow)
        #expect(sections.first?.fraction == 1)
    }

    @Test func legacyHeadersAreFallback() {
        let sections = ClaudeProvider.sections(from: .stub(headers: [
            "anthropic-ratelimit-requests-limit": "100",
            "anthropic-ratelimit-requests-remaining": "75",
        ]), now: testNow)
        #expect(sections.map(\.title) == ["Rate limit"])
        #expect(sections.first?.leading == "25% used")
    }

    @Test func legacyHeadersIgnoredWhenUnifiedPresent() {
        let sections = ClaudeProvider.sections(from: .stub(headers: [
            "anthropic-ratelimit-unified-7d-utilization": "0.1",
            "anthropic-ratelimit-requests-limit": "100",
            "anthropic-ratelimit-requests-remaining": "75",
        ]), now: testNow)
        #expect(sections.map(\.title) == ["Weekly"])
    }

    @Test func fetchUsesDisplayNameAsPlan() async throws {
        let snapshot = try await Self.provider(.success(.stub(headers: [
            "anthropic-ratelimit-unified-5h-utilization": "0.5",
        ]))).fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.map(\.title) == ["Session"])
        #expect(snapshot.note == nil)
    }

    @Test func noHeadersYieldsNoteWithStatus() async throws {
        let snapshot = try await Self.provider(.success(.stub(headers: [
            "anthropic-ratelimit-unified-status": "allowed",
        ]))).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note?.contains("status: allowed") == true)
    }

    @Test(arguments: [401, 403])
    func unauthorizedPropagates(status: Int) async {
        await #expect {
            _ = try await Self.provider(.failure(ProviderError.http(status: status, body: ""))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func apiKeyThrowsMissingConfiguration() async {
        let provider = ClaudeProvider(transport: { url, _, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        await #expect {
            _ = try await provider.fetch(.apiKey)
        } throws: { error in
            if case .missingConfiguration = error as? ProviderError { return true }
            return false
        }
    }
}
