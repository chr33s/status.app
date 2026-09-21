import Foundation
import Testing
@testable import status

struct GeminiProviderTests {
    private static let resetISO = ISO8601DateFormatter().string(from: testNow.addingTimeInterval(5 * 3_600 + 15 * 60))

    private static let quota: [String: Any] = [
        "buckets": [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.75, "resetTime": resetISO],
            ["modelId": "gemini-2.5-flash", "remainingAmount": "1000"],
        ],
    ]

    private static func provider(
        load: Result<Any, Error> = .success(["cloudaicompanionProject": "proj-1"]),
        quota: Result<Any, Error> = .success(quota),
        environment: [String: String] = [:]
    ) -> GeminiProvider {
        GeminiProvider(transport: { url, headers, body in
            #expect(headers["Authorization"] == "Bearer token")
            if url == GeminiProvider.quotaURL {
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect(json?["project"] as? String == (environment["GOOGLE_CLOUD_PROJECT"] ?? "proj-1"))
                return try .stub(quota.get())
            }
            #expect(url == GeminiProvider.loadURL)
            return try .stub(load.get())
        }, environment: environment, now: { testNow })
    }

    @Test func quotaBucketsAreFoundAtAnyDepth() {
        let nested: [String: Any] = ["a": ["b": [Self.quota]]]
        #expect(GeminiProvider.quotaBuckets(in: nested).count == 2)
        #expect(GeminiProvider.quotaBuckets(in: ["modelId": "x"]).isEmpty)
    }

    @Test func sectionMapsRemainingFractionAndReset() {
        let section = GeminiProvider.section(from: JSON(["modelId": "pro", "remainingFraction": 0.75, "resetTime": Self.resetISO]), now: testNow)
        #expect(section.title == "pro")
        #expect(section.fraction == 0.25)
        #expect(section.leading == "25% used")
        #expect(section.trailing == "Resets in 5h 15m")
    }

    @Test func missingFractionMeansUnused() {
        let section = GeminiProvider.section(from: JSON(["modelId": "flash", "remainingAmount": "1000"]))
        #expect(section.fraction == 0)
        #expect(section.trailing == nil)
    }

    @Test func fetchLoadsProjectThenQuota() async throws {
        let snapshot = try await Self.provider().fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.map(\.title) == ["gemini-2.5-pro", "gemini-2.5-flash"])
        #expect(snapshot.note == nil)
    }

    @Test func environmentProjectIsFallback() async throws {
        let snapshot = try await Self.provider(load: .success([:]), environment: ["GOOGLE_CLOUD_PROJECT": "env-proj"]).fetch(.oauth)
        #expect(snapshot.sections.count == 2)
    }

    @Test func noProjectYieldsNote() async throws {
        let provider = Self.provider(load: .success([:]), quota: .failure(ProviderError.invalidResponse))
        let snapshot = try await provider.fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note?.contains("No Cloud project") == true)
    }

    @Test func emptyQuotaYieldsNote() async throws {
        let snapshot = try await Self.provider(quota: .success([:])).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }

    @Test(arguments: [401, 403])
    func unauthorizedPropagates(status: Int) async {
        await #expect {
            _ = try await Self.provider(quota: .failure(ProviderError.http(status: status, body: ""))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func apiKeyDoesNotCallApi() async throws {
        let provider = GeminiProvider(transport: { url, _, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        let snapshot = try await provider.fetch(.apiKey)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }
}
