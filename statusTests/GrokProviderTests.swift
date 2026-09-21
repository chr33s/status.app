import Foundation
import Testing
@testable import status

struct GrokProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// 3 days 4 hours after `now`.
    private static let weeklyEnd = ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 86_400 + 4 * 3_600))

    private static func billing(percent: Any? = 42, type: String = "USAGE_PERIOD_TYPE_WEEKLY", cap: Any? = 2500) -> [String: Any] {
        var config: [String: Any] = [
            "currentPeriod": ["type": type, "start": "2026-09-19T00:00:00Z", "end": weeklyEnd],
        ]
        if let percent { config["creditUsagePercent"] = percent }
        if let cap { config["onDemandCap"] = ["val": cap] }
        return ["config": config]
    }

    private static func result(_ body: Any) -> HTTPResult {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return HTTPResult(json: JSON(body), data: data, headers: [:], status: 200)
    }

    private static func provider(
        billing: Result<Any, Error>,
        settings: Result<Any, Error> = .success(["subscription_tier_display": "SuperGrok"])
    ) -> GrokProvider {
        GrokProvider(transport: { url, headers in
            #expect(headers["X-XAI-Token-Auth"] == "xai-grok-cli")
            #expect(headers["Authorization"] == "Bearer token")
            let response = url == GrokProvider.billingURL ? billing : settings
            return try result(response.get())
        }, now: { now })
    }

    private static let request = ProviderRequest(credential: .oauth(accessToken: "token", accountID: nil, displayName: "me@example.com"))

    @Test func weeklyMapsPercentAndReset() throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing()), now: Self.now)
        let weekly = try #require(sections.first { $0.title == "Weekly" })
        #expect(weekly.fraction == 0.42)
        #expect(weekly.leading == "42% used")
        #expect(weekly.trailing == "Resets in 3d 4h")
    }

    @Test func missingPercentMapsToZero() throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing(percent: nil)), now: Self.now)
        let weekly = try #require(sections.first { $0.title == "Weekly" })
        #expect(weekly.fraction == 0)
        #expect(weekly.leading == "0% used")
    }

    @Test func percentIsClamped() throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing(percent: 130)), now: Self.now)
        #expect(sections.first { $0.title == "Weekly" }?.fraction == 1)
    }

    @Test func nonWeeklyPeriodOmitsWeekly() throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing(type: "USAGE_PERIOD_TYPE_MONTHLY")), now: Self.now)
        #expect(sections.map(\.title) == ["Extra Usage"])
    }

    @Test func positiveCapIsDisplayed() throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing(cap: "2500")), now: Self.now)
        #expect(sections.first { $0.title == "Extra Usage" }?.leading == "2500 cap")
    }

    @Test(arguments: [nil, 0] as [Int?])
    func missingOrZeroCapIsDisabled(cap: Int?) throws {
        let sections = try GrokProvider.parseBilling(JSON(Self.billing(cap: cap)), now: Self.now)
        #expect(sections.first { $0.title == "Extra Usage" }?.leading == "Disabled")
    }

    @Test func malformedBillingThrowsDecoding() {
        #expect {
            try GrokProvider.parseBilling(JSON(["unexpected": true]))
        } throws: { error in
            if case .decoding = error as? ProviderError { return true }
            return false
        }
    }

    @Test(arguments: [401, 403])
    func unauthorizedPropagates(status: Int) async {
        let provider = Self.provider(billing: .failure(ProviderError.http(status: status, body: "")))
        await #expect {
            _ = try await provider.fetch(Self.request)
        } throws: { error in
            (error as? ProviderError)?.isUnauthorized == true
        }
    }

    @Test func settingsSetsPlanName() async throws {
        let snapshot = try await Self.provider(billing: .success(Self.billing())).fetch(Self.request)
        #expect(snapshot.planName == "SuperGrok")
        #expect(snapshot.sections.map(\.title) == ["Weekly", "Extra Usage"])
    }

    @Test func settingsFailureKeepsBillingUsage() async throws {
        let provider = Self.provider(
            billing: .success(Self.billing()),
            settings: .failure(ProviderError.http(status: 500, body: ""))
        )
        let snapshot = try await provider.fetch(Self.request)
        #expect(snapshot.planName == "me@example.com")
        #expect(snapshot.sections.map(\.title) == ["Weekly", "Extra Usage"])
    }

    @Test func apiKeyDoesNotCallBilling() async throws {
        let provider = GrokProvider(transport: { url, _ in
            Issue.record("unexpected request to \(url)")
            throw ProviderError.invalidResponse
        })
        let snapshot = try await provider.fetch(ProviderRequest(credential: .apiKey("xai-key")))
        #expect(snapshot.sections.isEmpty)
        #expect(snapshot.note != nil)
    }
}
