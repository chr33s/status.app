import Foundation

/// Accumulated usage reported by a CLI over OpenTelemetry since the collector
/// started. Counts are summed from delta-temporality exports.
struct TelemetryUsage: Sendable, Equatable {
    var inputTokens = 0.0
    var outputTokens = 0.0
    var cacheTokens = 0.0
    var cost = 0.0
    var requests = 0.0
    var lastUpdate: Date?

    var totalTokens: Double { inputTokens + outputTokens + cacheTokens }
    var hasData: Bool { totalTokens > 0 || cost > 0 || requests > 0 }

    static func += (lhs: inout TelemetryUsage, rhs: TelemetryUsage) {
        lhs.inputTokens += rhs.inputTokens
        lhs.outputTokens += rhs.outputTokens
        lhs.cacheTokens += rhs.cacheTokens
        lhs.cost += rhs.cost
        lhs.requests += rhs.requests
        if rhs.lastUpdate != nil { lhs.lastUpdate = rhs.lastUpdate }
    }
}
