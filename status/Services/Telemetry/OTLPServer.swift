import Foundation
import Network

/// A tiny loopback HTTP/1.1 server that accepts OTLP/HTTP requests (the CLIs
/// export OpenTelemetry as `application/json` POSTs to `/v1/metrics`,
/// `/v1/logs`, `/v1/traces`). It hands raw JSON bodies back to its owner and
/// always answers `200 {}` so exporters stay happy.
///
/// JSON-only by design: every supported CLI can be configured to send
/// `http/json`, so we avoid a protobuf/gRPC dependency entirely.
final class OTLPServer {
    /// Called on `queue` with the request path (e.g. "/v1/metrics") and body.
    var onRequest: ((String, Data) -> Void)?

    let port: UInt16
    private let queue = DispatchQueue(label: "app.status.otlp")
    private var listener: NWListener?

    init(port: UInt16 = 4318) { self.port = port }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — never accept connections from other hosts.
        params.requiredInterfaceType = .loopback

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data) }

            // Parse as many complete requests as the buffer holds.
            while let (path, body, consumed) = Self.parseRequest(buffer) {
                if let path { self.onRequest?(path, body) }
                connection.send(content: Self.okResponse, completion: .idempotent)
                buffer.removeSubrange(0..<consumed)
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Parses one HTTP request from the front of `buffer`. Returns the request
    /// path (nil for non-POSTs we ignore), the body, and the number of bytes
    /// consumed — or nil if a full request isn't buffered yet.
    private static func parseRequest(_ buffer: Data) -> (path: String?, body: Data, consumed: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = header
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : "/"

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil } // wait for more

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = buffer.subdata(in: bodyStart..<bodyEnd)
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyEnd)
        return (method == "POST" ? path : nil, body, consumed)
    }

    private static let okResponse: Data = {
        let body = "{}"
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: keep-alive\r
        \r
        \(body)
        """
        return Data(response.utf8)
    }()
}
