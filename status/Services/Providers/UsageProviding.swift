import Foundation

/// How a provider request is authenticated. Every credential is sourced from a
/// local CLI login — never entered by hand.
enum Credential: Sendable {
    /// An OAuth access token reused from a CLI login.
    /// - `accountID` is an opaque identifier the provider needs at request time
    ///   (Codex's ChatGPT account UUID, Copilot's GitHub login).
    /// - `displayName` is the user-facing label shown in the tab header
    ///   (email / login / plan tier). May equal `accountID` for providers
    ///   where the latter is already human-readable.
    case oauth(accessToken: String, accountID: String?, displayName: String?)
    /// A local API key found in a CLI's config or environment (e.g. OpenAI, Claude, xAI).
    case apiKey(String)
}

/// Inputs required to fetch usage for one provider.
struct ProviderRequest: Sendable {
    let credential: Credential
}

protocol UsageProviding: Sendable {
    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot
}

/// Resolves the concrete implementation for a provider.
enum ProviderFactory {
    static func make(_ provider: Provider) -> UsageProviding {
        switch provider {
        case .codex: return CodexProvider()
        case .claude: return ClaudeProvider()
        case .antigravity: return AntigravityProvider()
        case .copilot: return CopilotProvider()
        case .grok: return GrokProvider()
        }
    }
}
