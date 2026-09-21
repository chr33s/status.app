import Foundation
@testable import status

extension HTTPResult {
    /// A canned response. Header keys are lower-cased like `HTTPClient` does.
    static func stub(_ body: Any? = nil, headers: [String: String] = [:], status: Int = 200) -> HTTPResult {
        let data = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return HTTPResult(
            json: JSON(body),
            data: data,
            headers: Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }),
            status: status
        )
    }
}

extension ProviderRequest {
    static let oauth = ProviderRequest(credential: .oauth(accessToken: "token", accountID: "account", displayName: "me@example.com"))
    static let apiKey = ProviderRequest(credential: .apiKey("key"))
}

/// Fixed clock shared by provider tests.
let testNow = Date(timeIntervalSince1970: 1_790_000_000)
/// Epoch seconds 2 hours 30 minutes after `testNow`.
let testResetEpoch = String(Int(testNow.timeIntervalSince1970) + 2 * 3_600 + 30 * 60)
