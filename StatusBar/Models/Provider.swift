import SwiftUI

/// The AI subscriptions tracked by the app.
///
/// The order here drives the order of the tab strip at the top of the menu.
enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claude
    case gemini
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .copilot: return "Copilot"
        }
    }

    /// Long form shown in the detail header / settings.
    var fullName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .copilot: return "GitHub Copilot"
        }
    }

    var vendor: String {
        switch self {
        case .codex: return "OpenAI"
        case .claude: return "Anthropic"
        case .gemini: return "Google"
        case .copilot: return "GitHub"
        }
    }

    /// SF Symbol used in the tab strip and rows.
    var systemImage: String {
        switch self {
        case .codex: return "curlybraces"
        case .claude: return "sparkles"
        case .gemini: return "diamond.fill"
        case .copilot: return "cpu"
        }
    }

    var accentColor: Color {
        switch self {
        case .codex: return Color(red: 0.06, green: 0.71, blue: 0.51)   // OpenAI teal
        case .claude: return Color(red: 0.85, green: 0.46, blue: 0.30)  // Anthropic clay
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)  // Google blue
        case .copilot: return Color(red: 0.45, green: 0.45, blue: 0.50) // GitHub graphite
        }
    }

    /// Stable identifier used as the Keychain account name for the secret.
    var keychainAccount: String { "secret.\(rawValue)" }

    /// Where to send the user to view detailed usage in a browser.
    var dashboardURL: URL {
        switch self {
        case .codex: return URL(string: "https://platform.openai.com/usage")!
        case .claude: return URL(string: "https://console.anthropic.com/usage")!
        case .gemini: return URL(string: "https://aistudio.google.com/usage")!
        case .copilot: return URL(string: "https://github.com/settings/billing")!
        }
    }

    /// Provider status / incident page.
    var statusURL: URL {
        switch self {
        case .codex: return URL(string: "https://status.openai.com")!
        case .claude: return URL(string: "https://status.anthropic.com")!
        case .gemini: return URL(string: "https://status.cloud.google.com")!
        case .copilot: return URL(string: "https://www.githubstatus.com")!
        }
    }

    /// Help text describing the kind of key the provider expects.
    var keyHelp: String {
        switch self {
        case .codex:
            return "OpenAI Admin API key (sk-admin-…). Read-only; used for the organization usage & costs endpoints."
        case .claude:
            return "Anthropic Admin API key (sk-ant-admin…). Read-only; used for the organization usage & cost reports."
        case .gemini:
            return "Google AI Studio API key. Used to validate connectivity; usage figures require Cloud billing."
        case .copilot:
            return "GitHub fine-grained token with read-only \"Plan\" / billing access."
        }
    }

    /// Label for the optional, non-secret secondary identifier field.
    var identifierLabel: String {
        switch self {
        case .codex: return "Organization ID (optional)"
        case .claude: return "Organization ID (optional)"
        case .gemini: return "Cloud project ID (optional)"
        case .copilot: return "GitHub username (optional — auto-detected)"
        }
    }
}
