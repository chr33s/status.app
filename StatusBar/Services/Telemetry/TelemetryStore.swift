import Foundation

/// Runs the embedded OTLP collector and exposes the live, per-provider usage it
/// receives from the CLIs.
@MainActor
@Observable
final class TelemetryStore {
    private(set) var usage: [Provider: TelemetryUsage] = [:]
    private(set) var isRunning = false

    @ObservationIgnored let server = OTLPServer()
    var port: UInt16 { server.port }
    var endpoint: String { "http://localhost:\(server.port)" }

    /// Bursts of CLI exports are coalesced into one main-actor publish per
    /// window so the menu stays responsive while a CLI is actively streaming.
    @ObservationIgnored nonisolated private let coalesceInterval: TimeInterval = 0.2
    @ObservationIgnored nonisolated private let pendingQueue = DispatchQueue(label: "app.statusbar.telemetry.pending")
    @ObservationIgnored nonisolated(unsafe) private var pending: [Provider: TelemetryUsage] = [:]
    @ObservationIgnored nonisolated(unsafe) private var flushScheduled = false

    func start() {
        guard !isRunning else { return }
        server.onRequest = { [weak self] path, body in
            guard path.hasSuffix("/v1/metrics") else { return } // ignore logs/traces
            let deltas = OTelMetricsParser.parse(body)
            guard !deltas.isEmpty else { return }
            self?.enqueue(deltas)
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

    /// Accumulates deltas off-main and schedules a single flush per coalesce
    /// window. Bursts collapse into one `@Published` change instead of N.
    private nonisolated func enqueue(_ deltas: [Provider: TelemetryUsage]) {
        pendingQueue.async { [self] in
            for (provider, delta) in deltas {
                pending[provider, default: TelemetryUsage()] += delta
            }
            guard !flushScheduled else { return }
            flushScheduled = true
            pendingQueue.asyncAfter(deadline: .now() + coalesceInterval) { [self] in
                let drained = pending
                pending.removeAll(keepingCapacity: true)
                flushScheduled = false
                guard !drained.isEmpty else { return }
                Task { @MainActor in self.apply(drained) }
            }
        }
    }

    private func apply(_ deltas: [Provider: TelemetryUsage]) {
        for (provider, delta) in deltas {
            usage[provider, default: TelemetryUsage()] += delta
        }
    }
}
