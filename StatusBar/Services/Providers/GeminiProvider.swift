import Foundation

/// Gemini connectivity check via the Generative Language API.
///
/// Google does not expose per-key usage or quota figures through a simple API
/// key — those live in Cloud Monitoring / Billing behind OAuth. So this provider
/// validates the key (by listing models) and reports status, plus an optional
/// budget meter the user tracks manually.
struct GeminiProvider: UsageProviding {
    private let base = "https://generativelanguage.googleapis.com/v1beta"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        let apiKey = request.credential.token
        var comps = URLComponents(string: "\(base)/models")!
        comps.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "pageSize", value: "1"),
        ]
        // Validates the key; throws on auth failure.
        let json = JSON(try await HTTPClient.getJSON(comps.url!, headers: [:]))
        let modelCount = json["models"].array.count

        var snapshot = UsageSnapshot()
        snapshot.planName = "Connected"
        if let section = budgetSection(spent: 0, budget: request.monthlyBudget) {
            snapshot.sections.append(section)
        }
        if snapshot.sections.isEmpty {
            snapshot.note = modelCount > 0
                ? "Key is valid. Per-key usage isn't exposed by the Gemini API — open the Usage Dashboard for figures, or set a monthly budget to track a cap."
                : "Key is valid. Per-key usage isn't exposed by the Gemini API."
        }
        return snapshot
    }
}
