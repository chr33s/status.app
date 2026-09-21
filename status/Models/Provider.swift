import SwiftUI

/// The AI subscriptions tracked by the app. Each reuses the login of its
/// corresponding CLI — there are no API keys to enter.
///
/// The order here drives the order of the tab strip at the top of the menu.
enum Provider: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claude
    case antigravity
    case copilot
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .antigravity: return "Antigravity"
        case .copilot: return "Copilot"
        case .grok: return "Grok"
        }
    }

    var fullName: String {
        switch self {
        case .codex: return "OpenAI Codex"
        case .claude: return "Claude"
        case .antigravity: return "Google Antigravity"
        case .copilot: return "GitHub Copilot"
        case .grok: return "xAI Grok"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: return "curlybraces"
        case .claude: return "sparkles"
        case .antigravity: return "arrow.up.circle.fill"
        case .copilot: return "cpu"
        case .grok: return "x.circle.fill"
        }
    }

    /// Brand glyph from `Assets.xcassets/icons`. Rendered as a template so the
    /// view's foreground style controls the colour.
    var assetIcon: String {
        switch self {
        case .codex: return "openai"
        case .claude: return "claude"
        case .antigravity: return "antigravity"
        case .copilot: return "copilot"
        case .grok: return "grok"
        }
    }

    var accentColor: Color {
        switch self {
        case .codex: return Color(red: 0.06, green: 0.71, blue: 0.51)   // OpenAI teal
        case .claude: return Color(red: 0.85, green: 0.46, blue: 0.30)  // Anthropic clay
        case .antigravity: return Color(red: 0.26, green: 0.52, blue: 0.96) // Google blue
        case .copilot: return Color(red: 0.45, green: 0.45, blue: 0.50) // GitHub graphite
        case .grok: return Color(red: 0.20, green: 0.20, blue: 0.22)    // xAI near-black
        }
    }

    /// Name of the CLI whose login is reused.
    var cliName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .antigravity: return "Antigravity"
        case .copilot: return "Copilot CLI"
        case .grok: return "Grok CLI"
        }
    }

    /// Hint shown when no CLI login is found.
    var cliSignInHint: String {
        switch self {
        case .codex: return "Install the Codex CLI and run `codex login` to sign in."
        case .claude: return "Install Claude Code and run `claude` to sign in."
        case .antigravity: return "Install Antigravity and sign in, or run `agy` to sign in."
        case .copilot: return "Install the Copilot CLI and run `copilot login` to sign in."
        case .grok: return "Install the Grok CLI and run `grok login`, or set XAI_API_KEY in your shell."
        }
    }

    /// Command run in Terminal to (re)authenticate the CLI.
    var reauthCommand: String {
        switch self {
        case .codex: return "codex login --device-auth"
        case .claude: return "claude auth login"
        case .antigravity: return "agy"
        case .copilot: return "copilot login"
        case .grok: return "grok login"
        }
    }

    /// Where to send the user to view detailed usage in a browser.
    var dashboardURL: URL {
        switch self {
        case .codex: return URL(string: "https://platform.openai.com/usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .antigravity: return URL(string: "https://antigravity.google")!
        case .copilot: return URL(string: "https://github.com/settings/billing")!
        case .grok: return URL(string: "https://console.x.ai/team/default/usage")!
        }
    }

    /// Provider status / incident page.
    var statusURL: URL {
        switch self {
        case .codex: return URL(string: "https://status.openai.com")!
        case .claude: return URL(string: "https://status.anthropic.com")!
        case .antigravity: return URL(string: "https://status.cloud.google.com")!
        case .copilot: return URL(string: "https://www.githubstatus.com")!
        case .grok: return URL(string: "https://status.x.ai")!
        }
    }
}
