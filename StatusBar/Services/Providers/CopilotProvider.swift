import Foundation

/// GitHub Copilot usage via the enhanced billing platform.
/// Requires a fine-grained token with read-only "Plan" / billing access.
///
/// Endpoints used (read-only):
///   • GET /user                                          — resolve login if not provided
///   • GET /users/{login}/settings/billing/usage          — metered usage items
struct CopilotProvider: UsageProviding {
    private let api = "https://api.github.com"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer \(request.apiKey)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]

        // Resolve the username if the user didn't provide one.
        var login = request.identifier
        if login.isEmpty {
            let me = JSON(try await HTTPClient.getJSON(URL(string: "\(api)/user")!, headers: headers))
            guard let resolved = me["login"].string else {
                throw ProviderError.missingConfiguration("Couldn't resolve the GitHub username from the token.")
            }
            login = resolved
        }

        let calendar = Calendar.current
        let now = Date()
        var comps = URLComponents(string: "\(api)/users/\(login)/settings/billing/usage")!
        comps.queryItems = [
            URLQueryItem(name: "year", value: String(calendar.component(.year, from: now))),
            URLQueryItem(name: "month", value: String(calendar.component(.month, from: now))),
        ]
        let json = JSON(try await HTTPClient.getJSON(comps.url!, headers: headers))

        // Filter the metered items down to Copilot.
        var requests = 0.0
        var grossAmount = 0.0
        var discount = 0.0
        for item in json["usageItems"].array {
            let product = (item["product"].string ?? "").lowercased()
            guard product.contains("copilot") else { continue }
            requests += item["quantity"].double ?? 0
            grossAmount += item["grossAmount"].double ?? item["netAmount"].double ?? 0
            discount += item["discountAmount"].double ?? 0
        }
        let netAmount = max(0, grossAmount - discount)

        var snapshot = UsageSnapshot()
        snapshot.planName = login

        // Premium request meter. If a budget (allowance) is configured, show the
        // fill against it; otherwise just report the count.
        if let allowance = request.monthlyBudget, allowance > 0 {
            let fraction = min(max(requests / allowance, 0), 1)
            snapshot.sections.append(UsageSection(
                title: "Premium requests",
                fraction: fraction,
                leading: "\(Int(requests)) / \(Int(allowance)) requests",
                trailing: Format.percentUsed(fraction)
            ))
        } else if requests > 0 {
            snapshot.sections.append(UsageSection(
                title: "Premium requests",
                fraction: nil,
                leading: "\(Int(requests)) requests this month",
                trailing: nil
            ))
        }

        snapshot.cost = CostInfo(
            todayAmount: nil,
            todayTokens: nil,
            last30Amount: netAmount,
            last30Tokens: nil
        )
        if snapshot.sections.isEmpty {
            snapshot.note = "No metered Copilot usage reported for this month yet."
        }
        return snapshot
    }
}
