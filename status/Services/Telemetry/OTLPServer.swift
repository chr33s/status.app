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
    var onStateChange: ((NWListener.State) -> Void)?

    let port: UInt16
    var listeningPort: UInt16? { listener?.port?.rawValue }
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
        listener.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
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
            do {
                while let (path, body, consumed) = try Self.parseRequest(buffer) {
                    if let path { self.onRequest?(path, body) }
                    connection.send(content: Self.okResponse, completion: .idempotent)
                    buffer.removeFirst(consumed)
                }
            } catch {
                connection.cancel()
                return
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
    enum RequestError: Error { case invalidRequest }
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    static func parseRequest(_ buffer: Data) throws -> (path: String?, body: Data, consumed: Int)? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= maxHeaderBytes else { throw RequestError.invalidRequest }
            return nil
        }
        guard buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound) <= maxHeaderBytes else {
            throw RequestError.invalidRequest
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let header = String(data: headerData, encoding: .utf8) else { throw RequestError.invalidRequest }

        // CRLF is a single Swift Character, so splitting on the LF
        // Character alone never separates standard HTTP header lines.
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw RequestError.invalidRequest }
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw RequestError.invalidRequest
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength: Int?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                let raw = pair[1].trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(raw), length <= maxBodyBytes,
                      contentLength == nil || contentLength == length else {
                    throw RequestError.invalidRequest
                }
                contentLength = length
            } else if pair.count == 2, pair[0].lowercased() == "transfer-encoding" {
                // Chunked framing is unsupported; never treat its chunks as new requests.
                throw RequestError.invalidRequest
            }
        }
        let length = contentLength ?? 0

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= length else { return nil } // wait for more

        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
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
