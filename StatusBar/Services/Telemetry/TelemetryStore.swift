import Combine
import Foundation

/// Runs the embedded OTLP collector and exposes the live, per-provider usage it
/// receives from the CLIs.
@MainActor
final class TelemetryStore: ObservableObject {
    @Published private(set) var usage: [Provider: TelemetryUsage] = [:]
    @Published private(set) var isRunning = false

    let server = OTLPServer()
    var port: UInt16 { server.port }
    var endpoint: String { "http://localhost:\(server.port)" }

    func start() {
        guard !isRunning else { return }
        server.onRequest = { [weak self] path, body in
            guard path.hasSuffix("/v1/metrics") else { return } // ignore logs/traces
            let deltas = OTelMetricsParser.parse(body)
            guard !deltas.isEmpty else { return }
            Task { @MainActor in self?.apply(deltas) }
        }
        do {
            try server.start()
            isRunning = true
        } catch {
            NSLog("OTLP collector failed to start on port \(server.port): \(error.localizedDescription)")
        }
    }

    func stop() {
        server.stop()
        isRunning = false
    }

    func usage(for provider: Provider) -> TelemetryUsage {
        usage[provider] ?? TelemetryUsage()
    }

    private func apply(_ deltas: [Provider: TelemetryUsage]) {
        for (provider, delta) in deltas {
            usage[provider, default: TelemetryUsage()] += delta
        }
    }
}
