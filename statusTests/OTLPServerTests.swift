import Foundation
import Testing
@testable import status

struct OTLPServerTests {
    @Test func fragmentedBodyWaitsAndPipelinedRequestsRemainSeparate() throws {
        let header = "POST /v1/metrics HTTP/1.1\r\nContent-Length: 2\r\n\r\n"
        #expect(try OTLPServer.parseRequest(Data((header + "{").utf8)) == nil)
        let request = Data((header + "{}").utf8)
        var buffer = request + request
        let first = try #require(try OTLPServer.parseRequest(buffer))
        #expect(first.path == "/v1/metrics")
        #expect(first.body == Data("{}".utf8))
        #expect(first.consumed == request.count)
        buffer.removeFirst(first.consumed)
        let second = try #require(try OTLPServer.parseRequest(buffer))
        #expect(second.body == Data("{}".utf8))
        #expect(second.consumed == request.count)
    }

    @Test(arguments: ["-1", "abc", "999999999999999999999999", "4194305", "+2"])
    func invalidLengthsAreRejected(_ length: String) {
        let request = Data("POST /v1/metrics HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n{}".utf8)
        #expect(throws: OTLPServer.RequestError.self) { try OTLPServer.parseRequest(request) }
    }

    @Test func conflictingLengthsAndChunkedFramingAreRejected() {
        for headers in ["Content-Length: 2\r\nContent-Length: 3", "Transfer-Encoding: chunked"] {
            let request = Data("POST /v1/metrics HTTP/1.1\r\n\(headers)\r\n\r\n{}".utf8)
            #expect(throws: OTLPServer.RequestError.self) { try OTLPServer.parseRequest(request) }
        }
    }

    @Test func oversizedUnterminatedHeadersAreRejected() {
        #expect(throws: OTLPServer.RequestError.self) {
            try OTLPServer.parseRequest(Data(repeating: 65, count: OTLPServer.maxHeaderBytes + 1))
        }
    }
}
