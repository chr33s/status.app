import Foundation

/// GitHub Copilot usage via the **GitHub CLI** login (`gh` / Copilot plugin
/// OAuth token) — no API key.
///
/// Endpoints used (read-only):
///   • GET /user                                 — resolve login if not known
///   • GET /users/{login}/settings/billing/usage — metered usage items
struct CopilotProvider: UsageProviding {
    private let api = "https://api.github.com"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, accountID) = request.credential else {
            throw ProviderError.missingConfiguration("No GitHub CLI login found.")
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]

        var login = accountID ?? ""
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
        if requests > 0 {
            snapshot.sections.append(UsageSection(
                title: "Premium requests",
                fraction: nil,
                leading: "\(Int(requests)) requests this month",
                trailing: nil
            ))
        }
        snapshot.cost = CostInfo(todayAmount: nil, todayTokens: nil, last30Amount: netAmount, last30Tokens: nil)
        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in as \(login). No metered Copilot usage reported this month yet."
        }
        return snapshot
    }
}
