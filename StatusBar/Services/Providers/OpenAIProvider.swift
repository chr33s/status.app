import Foundation

/// Codex / OpenAI usage via the Organization Costs & Usage APIs.
/// Requires an Admin key (`sk-admin-…`) with read access.
///
/// Endpoints used (read-only):
///   • GET /v1/organization/costs                — spend, bucketed daily
///   • GET /v1/organization/usage/completions     — token counts
struct OpenAIProvider: UsageProviding {
    private let base = "https://api.openai.com/v1/organization"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        var headers = ["Authorization": "Bearer \(request.apiKey)"]
        if !request.identifier.isEmpty {
            headers["OpenAI-Organization"] = request.identifier
        }

        let startOfWindow = Int(Date.thirtyDaysAgo.timeIntervalSince1970)
        let todayStart = Date.startOfToday
        let monthStart = Date.startOfMonth

        // Costs, daily buckets.
        var costComps = URLComponents(string: "\(base)/costs")!
        costComps.queryItems = [
            URLQueryItem(name: "start_time", value: String(startOfWindow)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        let costJSON = JSON(try await HTTPClient.getJSON(costComps.url!, headers: headers))

        var last30Amount = 0.0
        var todayAmount = 0.0
        var monthAmount = 0.0
        for bucket in costJSON["data"].array {
            let bucketStart = bucket["start_time"].double.map { Date(timeIntervalSince1970: $0) }
            var bucketTotal = 0.0
            for result in bucket["results"].array {
                bucketTotal += result["amount"]["value"].double ?? result["amount"].double ?? 0
            }
            last30Amount += bucketTotal
            if let bucketStart, bucketStart >= todayStart { todayAmount += bucketTotal }
            if let bucketStart, bucketStart >= monthStart { monthAmount += bucketTotal }
        }

        // Token usage, daily buckets.
        var last30Tokens = 0.0
        var todayTokens = 0.0
        var usageComps = URLComponents(string: "\(base)/usage/completions")!
        usageComps.queryItems = [
            URLQueryItem(name: "start_time", value: String(startOfWindow)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        if let usageData = try? await HTTPClient.getJSON(usageComps.url!, headers: headers) {
            let usageJSON = JSON(usageData)
            for bucket in usageJSON["data"].array {
                let bucketStart = bucket["start_time"].double.map { Date(timeIntervalSince1970: $0) }
                var tokens = 0.0
                for result in bucket["results"].array {
                    tokens += (result["input_tokens"].double ?? 0)
                    tokens += (result["output_tokens"].double ?? 0)
                }
                last30Tokens += tokens
                if let bucketStart, bucketStart >= todayStart { todayTokens += tokens }
            }
        }

        var snapshot = UsageSnapshot()
        if let section = budgetSection(spent: monthAmount, budget: request.monthlyBudget) {
            snapshot.sections.append(section)
        }
        snapshot.cost = CostInfo(
            todayAmount: todayAmount,
            todayTokens: todayTokens > 0 ? todayTokens : nil,
            last30Amount: last30Amount,
            last30Tokens: last30Tokens > 0 ? last30Tokens : nil
        )
        if snapshot.sections.isEmpty {
            snapshot.note = "Spend & token usage shown below. Set a monthly budget to track an \"Extra usage\" cap."
        }
        return snapshot
    }
}
