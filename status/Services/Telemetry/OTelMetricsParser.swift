import Foundation

/// Parses an OTLP/JSON metrics payload into per-provider usage increments.
///
/// Only vendor-prefixed counters are read (`claude_code.*`, `gemini_cli.*`,
/// `codex*`, `copilot*`) so generic `gen_ai.*` histograms — which some CLIs emit
/// alongside the vendor counters — don't double-count.
///
/// ── Verify on a real Mac ──
/// Exporters should be configured for **delta** temporality so summing each
/// datapoint yields a running total. Metric/attribute names are isolated here.
enum OTelMetricsParser {
    static func parse(_ data: Data) -> [Provider: TelemetryUsage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        let json = JSON(root)

        var result: [Provider: TelemetryUsage] = [:]
        for resource in json["resourceMetrics"].array {
            for scope in resource["scopeMetrics"].array {
                for metric in scope["metrics"].array {
                    guard let name = metric["name"].string,
                          let provider = provider(forMetric: name) else { continue }
                    accumulate(metric, name: name, into: &result[provider, default: TelemetryUsage()])
                }
            }
        }
        let now = Date()
        for key in result.keys where result[key]?.hasData == true {
            result[key]?.lastUpdate = now
        }
        return result
    }

    private static func provider(forMetric name: String) -> Provider? {
        if name.hasPrefix("claude_code.") { return .claude }
        if name.hasPrefix("gemini_cli.") { return .gemini }
        if name.hasPrefix("codex") { return .codex }
        if name.hasPrefix("copilot") { return .copilot }
        if name.hasPrefix("grok") || name.hasPrefix("xai") { return .grok }
        return nil
    }

    private static func accumulate(_ metric: JSON, name: String, into usage: inout TelemetryUsage) {
        // Counters live under "sum"; the rare gauge under "gauge".
        let points = metric["sum"]["dataPoints"].array + metric["gauge"]["dataPoints"].array
        for point in points {
            let value = point["asDouble"].double ?? point["asInt"].double ?? 0
            guard value != 0 else { continue }

            if name.contains("cost") {
                usage.cost += value
            } else if name.contains("token") {
                switch tokenType(of: point) {
                case .input: usage.inputTokens += value
                case .output: usage.outputTokens += value
                case .cache: usage.cacheTokens += value
                case .unknown: usage.inputTokens += value
                }
            } else if name.contains("request") {
                usage.requests += value
            }
        }
    }

    private enum TokenKind { case input, output, cache, unknown }

    private static func tokenType(of point: JSON) -> TokenKind {
        for attribute in point["attributes"].array {
            let key = attribute["key"].string ?? ""
            guard key == "type" || key.hasSuffix("token.type") else { continue }
            let value = (attribute["value"]["stringValue"].string ?? "").lowercased()
            if value.contains("cache") { return .cache }
            if value.contains("input") || value.contains("prompt") { return .input }
            if value.contains("output") || value.contains("completion") { return .output }
        }
        return .unknown
    }
}
