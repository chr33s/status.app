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

    /// What the daily deployment answered on 2026-10-16: weekly-only, and the
    /// Gemini group missing altogether.
    private static let dailySummary: [String: Any] = [
        "groups": [
            ["buckets": [["bucketId": "3p-weekly", "remainingFraction": 1.0, "resetTime": resetISO]]],
        ],
    ]

    /// Production's answer for the same account and moment.
    private static let productionSummary: [String: Any] = [
        "groups": [
            ["buckets": [["bucketId": "gemini-weekly", "remainingFraction": 0.0, "resetTime": resetISO]]],
            ["buckets": [["bucketId": "3p-weekly", "remainingFraction": 1.0, "resetTime": resetISO]]],
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
        productionSummary: Result<Any, Error>? = nil,
        quota: Result<Any, Error> = .success(quota),
        requested: Requests? = nil
    ) -> AntigravityProvider {
        AntigravityProvider(transport: { url, headers, body in
            #expect(headers["Authorization"] == "Bearer token")
            requested?.append(url)
            switch url.lastPathComponent {
            case AntigravityProvider.summaryPath:
                // Project-scoped: omitting `project` gets a 403 licensing error.
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                if case .success = load { #expect(json?["project"] as? String == "proj-1") }
                if let productionSummary, url.host() == AntigravityProvider.baseURLs.last?.host() {
                    return try .stub(productionSummary.get())
                }
                return try .stub(summary.get())
            case AntigravityProvider.loadPath:
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                #expect((json?["metadata"] as? [String: Any])?["ideType"] as? String == "ANTIGRAVITY")
                return try .stub(load.get())
            case AntigravityProvider.quotaPath:
                let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                if case .success = load { #expect(json?["project"] as? String == "proj-1") }
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

    /// Daily omits the Gemini group; production has it. The merge must show
    /// both pools, and a bucket both report keeps its worst fraction.
    @Test func summaryMergesDeploymentsWorstFractionWins() throws {
        let sections = try #require(AntigravityProvider.summarySections(
            in: [JSON(Self.dailySummary), JSON(Self.productionSummary)], now: testNow
        ))
        #expect(sections.map(\.title) == ["Weekly", "Claude Weekly"])
        #expect(sections[0].fraction == 1)
        #expect(sections[1].fraction == 0)

        let sentinel: [String: Any] = ["groups": [["buckets": [["bucketId": "gemini-weekly", "remainingFraction": 1.0]]]]]
        let merged = try #require(AntigravityProvider.summarySections(
            in: [JSON(Self.productionSummary), JSON(sentinel)], now: testNow
        ))
        #expect(merged.first?.fraction == 1)
    }

    @Test func summaryMergeIgnoresNonSummaryBodies() {
        let sections = AntigravityProvider.summarySections(in: [JSON(["other": 1]), JSON(Self.dailySummary)], now: testNow)
        #expect(sections?.map(\.title) == ["Claude Weekly"])
        #expect(AntigravityProvider.summarySections(in: [JSON(["other": 1]), JSON(nil)], now: testNow) == nil)
        #expect(AntigravityProvider.summarySections(in: [], now: testNow) == nil)
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

    @Test func fetchQueriesBothDeploymentsForSummary() async throws {
        let requests = Requests()
        let snapshot = try await Self.provider(
            summary: .success(Self.dailySummary), productionSummary: .success(Self.productionSummary), requested: requests
        ).fetch(.oauth)
        #expect(snapshot.sections.map(\.title) == ["Weekly", "Claude Weekly"])
        #expect(snapshot.sections.first?.fraction == 1)
        let summaries = requests.all.filter { $0.lastPathComponent == AntigravityProvider.summaryPath }
        #expect(summaries.map { $0.host() } == AntigravityProvider.baseURLs.map { $0.host() })
        // loadCodeAssist still stops at the first success.
        #expect(requests.all.filter { $0.lastPathComponent == AntigravityProvider.loadPath }.count == 1)
    }

    @Test func fetchUsesWhicheverDeploymentAnswers() async throws {
        let snapshot = try await Self.provider(
            summary: .failure(ProviderError.http(status: 503, body: "")), productionSummary: .success(Self.productionSummary)
        ).fetch(.oauth)
        #expect(snapshot.sections.map(\.title) == ["Weekly", "Claude Weekly"])
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

    @Test func unauthorizedPropagates() async {
        await #expect {
            _ = try await Self.provider(summary: .failure(ProviderError.http(status: 401, body: ""))).fetch(.oauth)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    /// The API answers 403 "no valid license" to authenticated requests it
    /// dislikes — that must fall back to the legacy quota, not demand re-auth.
    @Test func licenseErrorFallsBackToLegacyQuota() async throws {
        let snapshot = try await Self.provider(
            summary: .failure(ProviderError.http(status: 403, body: "You do not have a valid license"))
        ).fetch(.oauth)
        #expect(snapshot.sections.map(\.title) == ["Session", "Claude"])
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

    @Test func dailyHostIsPrimary() {
        #expect(AntigravityProvider.baseURLs.first?.host() == "daily-cloudcode-pa.googleapis.com")
    }

    @Test func resetCacheCanBeCalled() {
        LocalCredentials.resetCache(for: .antigravity)
    }

    @Test func geminiSupplementUsesWorstModelAndWeeklyTitle() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 86_400))
        let json = JSON(["buckets": [
            ["modelId": "gemini-2.5-pro", "remainingFraction": 0.27, "resetTime": reset],
            ["modelId": "gemini-3-flash", "remainingFraction": 0.5, "resetTime": reset],
            ["modelId": "claude-sonnet-4-6", "remainingFraction": 1.0, "resetTime": reset],
        ]])
        let section = try #require(AntigravityProvider.geminiSupplement(in: json, now: now))
        #expect(section.title == "Weekly")
        #expect(abs((section.fraction ?? 0) - 0.73) < 0.001)
    }

    @Test func geminiSupplementIsNilWithoutGeminiModels() {
        let json = JSON(["buckets": [["modelId": "claude-sonnet-4-6", "remainingFraction": 1.0]]])
        #expect(AntigravityProvider.geminiSupplement(in: json) == nil)
    }

    @Test func summaryWithoutGeminiIsSupplementedFromLegacyQuota() async throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let reset = ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 86_400))
        let provider = AntigravityProvider(transport: { url, _, _ in
            if url.absoluteString.hasSuffix("loadCodeAssist") {
                return .stub(["cloudaicompanionProject": "p"])
            }
            if url.absoluteString.hasSuffix("retrieveUserQuotaSummary") {
                return .stub(["groups": [["buckets": [
                    ["bucketId": "3p-weekly", "remainingFraction": 1.0, "resetTime": reset],
                ]]]])
            }
            return .stub(["buckets": [["modelId": "gemini-2.5-pro", "remainingFraction": 0.25, "resetTime": reset]]])
        }, now: { now })
        let snapshot = try await provider.fetch(ProviderRequest(credential: .oauth(accessToken: "t", accountID: nil, displayName: nil)))
        #expect(snapshot.sections.map(\.title) == ["Weekly", "Claude Weekly"])
    }
}
