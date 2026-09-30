import Foundation
import Testing
@testable import status

@MainActor
struct TelemetryStoreTests {
    private func waitFor(_ condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func loopbackHTTPMetricsReachTheStore() async throws {
        // Bind an ephemeral port, avoiding the user's running collector.
        let server = OTLPServer(port: 0)
        let store = TelemetryStore(server: server)
        store.start()
        defer { store.stop() }
        let ready = try await waitFor { store.isRunning }
        #expect(ready)
        guard ready else { return }
        let port = try #require(server.listeningPort)
        let payload: [String: Any] = ["resourceMetrics": [["scopeMetrics": [["metrics": [
            ["name": "claude_code.token.usage", "sum": ["aggregationTemporality": 1, "dataPoints": [
                ["asInt": "42", "attributes": [["key": "type", "value": ["stringValue": "input"]]]],
            ]]],
            ["name": "claude_code.cost.usage", "sum": ["aggregationTemporality": 1, "dataPoints": [["asDouble": 0.25]]]],
        ]]]]]]
        var request = URLRequest(url: try #require(URL(string: "http://localhost:\(port)/v1/metrics")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == Data("{}".utf8))
        let received = try await waitFor { store.usage(for: .claude).hasData }
        #expect(received)
        #expect(store.usage(for: .claude).inputTokens == 42)
        #expect(store.usage(for: .claude).cost == 0.25)
        store.stop()
        #expect(!store.isRunning)
    }
}
