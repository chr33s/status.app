import Foundation

/// How a provider request is authenticated.
enum Credential: Sendable {
    /// A read-only API key (Gemini, Copilot).
    case apiKey(String)
    /// An OAuth access token reused from a local CLI login (Claude Code, Codex),
    /// plus an optional account id (Codex / ChatGPT).
    case oauth(accessToken: String, accountID: String?)

    var token: String {
        switch self {
        case .apiKey(let value): return value
        case .oauth(let token, _): return token
        }
    }
}

/// Inputs required to fetch usage for one provider.
struct ProviderRequest: Sendable {
    let credential: Credential
    /// Optional, non-secret identifier (org id, project id, username).
    let identifier: String
    /// Optional monthly budget (USD) used to render the "Extra usage" meter.
    let monthlyBudget: Double?
}

protocol UsageProviding: Sendable {
    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot
}

extension UsageProviding {
    /// Builds the shared "Extra usage" budget meter from spend-to-date.
    func budgetSection(spent: Double?, budget: Double?) -> UsageSection? {
        guard let budget, budget > 0 else { return nil }
        let used = spent ?? 0
        let fraction = min(max(used / budget, 0), 1)
        return UsageSection(
            title: "Extra usage",
            fraction: fraction,
            leading: "This month: \(Format.currency(used)) / \(Format.currency(budget))",
            trailing: Format.percentUsed(fraction)
        )
    }
}

/// Resolves the concrete implementation for a provider.
enum ProviderFactory {
    static func make(_ provider: Provider) -> UsageProviding {
        switch provider {
        case .codex: return CodexProvider()
        case .claude: return ClaudeProvider()
        case .gemini: return GeminiProvider()
        case .copilot: return CopilotProvider()
        }
    }
}
