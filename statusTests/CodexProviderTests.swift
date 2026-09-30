import Foundation
import Testing
@testable import status

struct CodexProviderTests {
    private static let rateHeaders = [
        "x-codex-primary-used-percent": "12",
        "x-codex-primary-reset-at": testResetEpoch,
        "x-codex-secondary-used-percent": "40",
    ]

    private static func provider(_ response: Result<HTTPResult, Error>) -> CodexProvider {
        CodexProvider(transport: { url, headers, body in
            #expect(url == CodexProvider.endpoint)
            #expect(headers["Authorization"] == "Bearer token")
            #expect(headers["chatgpt-account-id"] == "account")
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            #expect(json?["store"] as? Bool == false)
            return try response.get()
        }, now: { testNow })
    }

    @Test func headerSectionMapsPercentAndReset() throws {
        let section = try #require(CodexProvider.headerSection(
            title: "Session", prefix: "x-codex-primary", in: .stub(headers: Self.rateHeaders), now: testNow
        ))
        #expect(section.fraction == 0.12)
        #expect(section.leading == "12% used")
        #expect(section.trailing == "Resets in 2h 30m")
    }

    @Test func headerSectionsUseWindowDurationWhenOrderIsInverted() throws {
        let sections = CodexProvider.headerSections(in: .stub(headers: [
            "x-codex-primary-used-percent": "60",
            "x-codex-primary-window-minutes": "10080",
            "x-codex-secondary-used-percent": "20",
            "x-codex-secondary-window-minutes": "300",
        ]), now: testNow)

        #expect(sections.map(\.title) == ["Session", "Weekly"])
        #expect(try #require(sections.first).fraction == 0.20)
        #expect(try #require(sections.last).fraction == 0.60)
    }

    @Test func headerSectionIsClamped() {
        let section = CodexProvider.headerSection(
            title: "Weekly", prefix: "x-codex-secondary",
            in: .stub(headers: ["x-codex-secondary-used-percent": "250"]), now: testNow
        )
        #expect(section?.fraction == 1)
    }

    @Test func missingPercentReturnsNil() {
        #expect(CodexProvider.headerSection(title: "Session", prefix: "x-codex-primary", in: .stub()) == nil)
    }

    @Test func fetchReadsHeadersEvenOn4xx() async throws {
        let snapshot = try await Self.provider(.success(.stub(headers: Self.rateHeaders, status: 400))).fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.map(\.title) == ["Session", "Weekly"])
        #expect(snapshot.note == nil)
    }

    @Test(arguments: [401, 403])
    func unauthorizedStatusThrows(status: Int) async {
        await #expect {
            _ = try await Self.provider(.success(.stub(headers: Self.rateHeaders, status: status))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func transportFailurePropagatesToPreserveStaleUsage() async {
        await #expect(throws: URLError.self) {
            _ = try await Self.provider(.failure(URLError(.timedOut))).fetch(.oauth)
        }
    }

    @Test func noHeadersYieldsNote() async throws {
        let snapshot = try await Self.provider(.success(.stub())).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }

    @Test func apiKeyDoesNotProbe() async throws {
        let provider = CodexProvider(transport: { url, _, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        let snapshot = try await provider.fetch(.apiKey)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }
}
