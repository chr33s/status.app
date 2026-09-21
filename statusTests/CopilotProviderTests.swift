import Foundation
import Testing
@testable import status

struct CopilotProviderTests {
    private static let user: [String: Any] = [
        "copilot_plan": "individual",
        // Midnight UTC, 2d 9h 46m after `testNow`.
        "quota_reset_date": "2026-09-24",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 225, "unlimited": false],
            "chat": ["unlimited": true],
            "completions": ["unlimited": true],
        ],
    ]

    private static func provider(_ response: Result<Any, Error>) -> CopilotProvider {
        CopilotProvider(transport: { url, headers in
            #expect(url == CopilotProvider.endpoint)
            #expect(headers["Authorization"] == "token token")
            return try .stub(response.get())
        }, now: { testNow })
    }

    @Test func premiumMapsRemainingAndReset() throws {
        let sections = CopilotProvider.sections(from: JSON(Self.user), now: testNow)
        #expect(sections.map(\.title) == ["Premium requests", "Chat", "Completions"])
        let premium = sections[0]
        #expect(premium.fraction == 0.25)
        #expect(premium.leading == "225 / 300 left")
        #expect(premium.trailing == "Resets in 2d 9h")
    }

    @Test func unlimitedHasNoMeter() {
        let chat = CopilotProvider.sections(from: JSON(Self.user), now: testNow)[1]
        #expect(chat.fraction == nil)
        #expect(chat.leading == "Unlimited")
    }

    @Test func overdrawnIsClamped() {
        let json = JSON(["quota_snapshots": ["premium_interactions": ["entitlement": 50, "remaining": -10]]])
        #expect(CopilotProvider.sections(from: json).first?.fraction == 1)
    }

    @Test(arguments: [
        ["entitlement": 0, "remaining": 0],
        ["remaining": 10],
        ["entitlement": 10],
    ] as [[String: Any]])
    func incompleteQuotaIsSkipped(bucket: [String: Any]) {
        let json = JSON(["quota_snapshots": ["premium_interactions": bucket]])
        #expect(CopilotProvider.sections(from: json).isEmpty)
    }

    @Test func fetchPrefersDisplayName() async throws {
        let snapshot = try await Self.provider(.success(Self.user)).fetch(.oauth)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.count == 3)
    }

    @Test func fetchFallsBackToPlan() async throws {
        let request = ProviderRequest(credential: .oauth(accessToken: "token", accountID: nil, displayName: nil))
        let snapshot = try await Self.provider(.success(Self.user)).fetch(request)
        #expect(snapshot.planName == "individual")
    }

    @Test func emptyQuotaYieldsNote() async throws {
        let snapshot = try await Self.provider(.success(["copilot_plan": "free"])).fetch(.oauth)
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
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
        await #expect {
            _ = try await Self.provider(.success(Self.user)).fetch(.apiKey)
        } throws: { error in
            if case .missingConfiguration = error as? ProviderError { return true }
            return false
        }
    }
}
