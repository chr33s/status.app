import Foundation

/// Claude usage via Anthropic's Admin API (requires an Admin key, `sk-ant-admin…`).
///
/// Endpoints used (read-only):
///   • GET /v1/organizations/cost_report      — spend, bucketed daily
///   • GET /v1/organizations/usage_report/messages — token counts
///
/// Per-subscription "Session"/"Weekly" rate-limit meters are not exposed by the
/// public API, so this maps the available cost & token data into the Cost block
/// and an optional budget meter.
struct AnthropicProvider: UsageProviding {
    private let base = "https://api.anthropic.com/v1/organizations"
    private let version = "2023-06-01"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        let headers = [
            "x-api-key": request.apiKey,
            "anthropic-version": version,
        ]
        let iso = ISO8601DateFormatter()

        // Last 30 days of cost, bucketed daily so we can split out "today".
        var costComps = URLComponents(string: "\(base)/cost_report")!
        costComps.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: .thirtyDaysAgo)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        let costJSON = JSON(try await HTTPClient.getJSON(costComps.url!, headers: headers))

        var last30Amount = 0.0
        var todayAmount = 0.0
        let todayStart = Date.startOfToday
        for bucket in costJSON["data"].array {
            let bucketStart = bucket["starting_at"].string.flatMap { iso.date(from: $0) }
            var bucketTotal = 0.0
            for result in bucket["results"].array {
                bucketTotal += result["amount"].double ?? 0
            }
            last30Amount += bucketTotal
            if let bucketStart, bucketStart >= todayStart { todayAmount += bucketTotal }
        }

        // Token usage over the same window.
        var usageComps = URLComponents(string: "\(base)/usage_report/messages")!
        usageComps.queryItems = [
            URLQueryItem(name: "starting_at", value: iso.string(from: .thirtyDaysAgo)),
            URLQueryItem(name: "bucket_width", value: "1d"),
        ]
        var last30Tokens = 0.0
        var todayTokens = 0.0
        if let usageData = try? await HTTPClient.getJSON(usageComps.url!, headers: headers) {
            let usageJSON = JSON(usageData)
            for bucket in usageJSON["data"].array {
                let bucketStart = bucket["starting_at"].string.flatMap { iso.date(from: $0) }
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
        if let section = budgetSection(spent: monthSpend(costJSON, iso: iso), budget: request.monthlyBudget) {
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

    /// Sum of buckets that fall in the current calendar month.
    private func monthSpend(_ json: JSON, iso: ISO8601DateFormatter) -> Double {
        let start = Date.startOfMonth
        var total = 0.0
        for bucket in json["data"].array {
            guard let bucketStart = bucket["starting_at"].string.flatMap({ iso.date(from: $0) }),
                  bucketStart >= start else { continue }
            for result in bucket["results"].array {
                total += result["amount"].double ?? 0
            }
        }
        return total
    }
}
