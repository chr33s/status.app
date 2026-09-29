import Foundation

/// Points each CLI's OpenTelemetry export at the embedded collector.
///
/// Claude is configured automatically by safely merging its JSON settings
/// file. Codex (`config.toml`) and Copilot (shell env) are offered as
/// copy-paste snippets so we never rewrite a TOML file or the user's shell rc.
///
/// ── Verify on a real Mac ──
/// Settings/metric/exporter keys are observed from each CLI's docs and isolated
/// here. JSON merges abort rather than clobber if a file can't be parsed.
///
/// Claude's settings file is only touched inside the user-granted `.claude`
/// folder; without a grant `configure`/`revert` throw
/// `SecurityScopedAccessError` and the UI asks for the folder.
enum OTelSetup {
    /// Whether a provider can be configured automatically (JSON) or needs a
    /// manual snippet.
    static func isAutomatic(_ provider: Provider) -> Bool {
        provider == .claude
    }

    // MARK: Apply / revert (Claude)

    static func configure(endpoint: String) throws {
        try configureClaude(endpoint: endpoint)
    }

    static func revert() throws {
        try revertClaude()
    }

    static func isConfigured(_ provider: Provider, endpoint: String) -> Bool {
        switch provider {
        case .claude:
            let settings = try? withClaudeSettings { readJSON($0) }
            let env = settings?["env"] as? [String: Any]
            return (env?["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String) == endpoint
                && env?["CLAUDE_CODE_ENABLE_TELEMETRY"] != nil
        default:
            return false
        }
    }

    /// Runs `operation` on `settings.json` inside the granted `.claude` folder.
    private static func withClaudeSettings<T>(_ operation: (URL) throws -> T) throws -> T {
        try SecurityScopedAccess.shared.withAccess(to: .claudeData) { root in
            guard let file = SecurityScopedAccess.file("settings.json", in: root) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try operation(file)
        }
    }

    private static func claudeEnv(_ endpoint: String) -> [String: String] {
        [
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
            "OTEL_METRIC_EXPORT_INTERVAL": "10000",
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "delta",
        ]
    }

    private static func configureClaude(endpoint: String) throws {
        try withClaudeSettings { file in
            // An existing file that doesn't parse is left alone rather than clobbered.
            if FileManager.default.fileExists(atPath: file.path), readJSON(file) == nil { return }
            var root = readJSON(file) ?? [:]
            var env = root["env"] as? [String: Any] ?? [:]
            for (key, value) in claudeEnv(endpoint) { env[key] = value }
            root["env"] = env
            writeJSON(root, to: file)
        }
    }

    private static func revertClaude() throws {
        try withClaudeSettings { file in
            guard var root = readJSON(file), var env = root["env"] as? [String: Any] else { return }
            for key in claudeEnv("").keys { env.removeValue(forKey: key) }
            root["env"] = env
            writeJSON(root, to: file)
        }
    }

    // MARK: Manual snippets (Codex + Copilot)

    static func manualSnippet(_ provider: Provider, endpoint: String) -> (file: String, snippet: String)? {
        switch provider {
        case .codex:
            return ("~/.codex/config.toml", """
            [otel]
            environment = "status"
            exporter = { otlp-http = { endpoint = "\(endpoint)", protocol = "json" } }
            """)
        case .copilot:
            return ("~/.zshrc (then restart the shell)", """
            export OTEL_EXPORTER_OTLP_ENDPOINT="\(endpoint)"
            export OTEL_EXPORTER_OTLP_PROTOCOL="http/json"
            export OTEL_METRICS_EXPORTER="otlp"
            export OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE="delta"
            """)
        default:
            return nil
        }
    }

    // MARK: JSON file helpers

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}
