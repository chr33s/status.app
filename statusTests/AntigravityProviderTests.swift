import Foundation
import Testing
@testable import status

struct AntigravityProviderTests {
    private static let resetISO = ISO8601DateFormatter().string(from: testNow.addingTimeInterval(5 * 3_600 + 15 * 60))

    private static let load: [String: Any] = [
        "cloudaicompanionProject": "proj-1",
        "currentTier": ["name": "Free"],
        "paidTier": ["name": "Gemini Code Assist in Google One AI Pro"],
    ]

    private static let summary: [String: Any] = [
        "groups": [
            ["buckets": [
                ["bucketId": "gemini-5h", "remainingFraction": 0.75, "resetTime": resetISO],
                ["bucketId": "gemini-weekly", "remainingFraction": 0.5],
            ]],
            ["buckets": [
                ["bucketId": "3p-5h", "remainingFraction": 1.0],
                ["bucketId": "3p-weekly"],
                ["bucketId": "gemini-image-5h", "remainingFraction": 0.1],
            ]],
        ],
    ]

    private static let quota: [String: Any] = [
        "buckets": [
            ["modelId": "gemini-3-pro", "remainingFraction": 0.75, "resetTime": resetISO],
            ["modelId": "gemini-3-flash", "remainingFraction": 0.25],
            ["modelId": "claude-sonnet-4-5", "remainingFraction": 0.9],
        ],
    ]

    private static func provider(
        load: Result<Any, Error> = .success(load),
        summary: Result<Any, Error> = .success(summary),
        quota: Result<Any, Error> = .success(quota),
        requested: Requests? = nil
    ) -> AntigravityProvider {
        AntigravityProvider(transport: { url, headers, body in
            #expect(headers["Authorization"] == "Bearer token")
            requested?.append(url)
            switch url.lastPathComponent {
            case AntigravityProvider.summaryPath: return try .stub(summary.get())
            case AntigravityProvider.loadPath: return try .stub(load.get())
            case AntigravityProvider.quotaPath:
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect(json?["project"] as? String == "proj-1")
                return try .stub(quota.get())
            default:
                Issue.record("unexpected request to \(url)")
                throw ProviderError.invalidResponse
            }
        }, now: { testNow })
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    @Test func summaryMapsPoolsInOrder() throws {
        let sections = try #require(AntigravityProvider.summarySections(in: JSON(Self.summary), now: testNow))
        #expect(sections.map(\.title) == ["Session", "Weekly", "Claude"])
        #expect(sections[0].fraction == 0.25)
        #expect(sections[0].trailing == "Resets in 5h 15m")
        #expect(sections[1].leading == "50% used")
        #expect(sections[2].fraction == 0)
    }

    @Test func summaryAcceptsLanguageServerEnvelope() {
        let wrapped = JSON(["response": Self.summary])
        #expect(AntigravityProvider.summarySections(in: wrapped)?.count == 3)
        #expect(AntigravityProvider.summarySections(in: JSON(["other": 1])) == nil)
    }

    @Test func legacyBucketsPoolWorstFraction() {
        let sections = AntigravityProvider.legacySections(in: JSON(Self.quota), now: testNow)
        #expect(sections.map(\.title) == ["Session", "Claude"])
        #expect(sections[0].fraction == 0.75)
        #expect(sections[0].trailing == nil)
        #expect(abs((sections[1].fraction ?? 0) - 0.1) < 0.0001)
    }

    @Test func planPrefersPaidTier() {
        #expect(AntigravityProvider.plan(from: JSON(Self.load)) == "Antigravity Pro")
        #expect(AntigravityProvider.plan(from: JSON(["currentTier": ["name": "Google AI Ultra"]])) == "Antigravity Ultra")
        #expect(AntigravityProvider.plan(from: JSON([:])) == nil)
    }

    @Test func fetchUsesSummary() async throws {
        let snapshot = try await Self.provider().fetch(.oauth)
        #expect(snapshot.planName == "Antigravity Pro")
        #expect(snapshot.sections.map(\.title) == ["Session", "Weekly", "Claude"])
        #expect(snapshot.note == nil)
    }

    @Test func fetchFallsBackToLegacyQuota() async throws {
        let snapshot = try await Self.provider(summary: .failure(ProviderError.http(status: 404, body: ""))).fetch(.oauth)
        #expect(snapshot.sections.map(\.title) == ["Session", "Claude"])
    }

    @Test func transientFailureTriesNextBase() async throws {
        let requests = Requests()
        let provider = Self.provider(load: .failure(ProviderError.http(status: 503, body: "")), requested: requests)
        let snapshot = try await provider.fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        let loads = requests.all.filter { $0.lastPathComponent == AntigravityProvider.loadPath }
        #expect(loads.map { $0.host() } == AntigravityProvider.baseURLs.map { $0.host() })
    }

    @Test func emptyQuotaYieldsNote() async throws {
        let snapshot = try await Self.provider(summary: .success([:]), quota: .success([:])).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }

    @Test(arguments: [401, 403])
    func unauthorizedPropagates(status: Int) async {
        await #expect {
            _ = try await Self.provider(summary: .failure(ProviderError.http(status: status, body: ""))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func apiKeyDoesNotCallApi() async throws {
        let provider = AntigravityProvider(transport: { url, _, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        let snapshot = try await provider.fetch(.apiKey)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }
}
