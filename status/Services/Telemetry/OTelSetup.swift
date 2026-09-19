import Foundation

/// Points each CLI's OpenTelemetry export at the embedded collector.
///
/// Claude and Gemini are configured automatically by safely merging their JSON
/// settings files. Codex (`config.toml`) and Copilot (shell env) are offered as
/// copy-paste snippets so we never rewrite a TOML file or the user's shell rc.
///
/// ── Verify on a real Mac ──
/// Settings/metric/exporter keys are observed from each CLI's docs and isolated
/// here. JSON merges abort rather than clobber if a file can't be parsed.
enum OTelSetup {
    /// Whether a provider can be configured automatically (JSON) or needs a
    /// manual snippet.
    static func isAutomatic(_ provider: Provider) -> Bool {
        provider == .claude || provider == .gemini
    }

    private static var home: URL { FileManager.default.realHomeDirectoryForCurrentUser }

    // MARK: Apply / revert (Claude + Gemini)

    static func configure(endpoint: String) {
        configureClaude(endpoint: endpoint)
        configureGemini(endpoint: endpoint)
    }

    static func revert() {
        revertClaude()
        revertGemini()
    }

    static func isConfigured(_ provider: Provider, endpoint: String) -> Bool {
        switch provider {
        case .claude:
            let env = readJSON(claudeSettings)?["env"] as? [String: Any]
            return (env?["OTEL_EXPORTER_OTLP_ENDPOINT"] as? String) == endpoint
                && env?["CLAUDE_CODE_ENABLE_TELEMETRY"] != nil
        case .gemini:
            let telemetry = readJSON(geminiSettings)?["telemetry"] as? [String: Any]
            return (telemetry?["enabled"] as? Bool == true)
                && (telemetry?["otlpEndpoint"] as? String) == endpoint
        default:
            return false
        }
    }

    private static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    private static var geminiSettings: URL { home.appendingPathComponent(".gemini/settings.json") }

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

    private static func configureClaude(endpoint: String) {
        var root = readJSON(claudeSettings) ?? [:]
        var env = root["env"] as? [String: Any] ?? [:]
        for (key, value) in claudeEnv(endpoint) { env[key] = value }
        root["env"] = env
        writeJSON(root, to: claudeSettings)
    }

    private static func revertClaude() {
        guard var root = readJSON(claudeSettings), var env = root["env"] as? [String: Any] else { return }
        for key in claudeEnv("").keys { env.removeValue(forKey: key) }
        root["env"] = env
        writeJSON(root, to: claudeSettings)
    }

    private static func configureGemini(endpoint: String) {
        var root = readJSON(geminiSettings) ?? [:]
        root["telemetry"] = [
            "enabled": true,
            "otlpProtocol": "http",
            "otlpEndpoint": endpoint,
            "useCollector": true,
            "logPrompts": false,
        ]
        writeJSON(root, to: geminiSettings)
    }

    private static func revertGemini() {
        guard var root = readJSON(geminiSettings), var telemetry = root["telemetry"] as? [String: Any] else { return }
        telemetry["enabled"] = false
        root["telemetry"] = telemetry
        writeJSON(root, to: geminiSettings)
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
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
