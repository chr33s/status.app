import Foundation

/// Outcome of an HTTP request: parsed JSON body plus the response headers
/// (lower-cased keys) and status code.
struct HTTPResult {
    let json: JSON
    /// Raw body — used for non-JSON responses such as SSE streams.
    let data: Data
    let headers: [String: String]
    let status: Int

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var text: String { String(data: data, encoding: .utf8) ?? "" }
}

/// Minimal async HTTP helper. Returns parsed JSON (as `Any`) so providers can
/// navigate response shapes defensively without brittle Codable models.
enum HTTPClient {
    static func getJSON(_ url: URL, headers: [String: String]) async throws -> Any {
        try await send(url, headers: headers).json.value ?? [:]
    }

    /// General request returning the body, headers, and status.
    /// - Parameter failOnError: When true (default), throws `ProviderError.http`
    ///   on non-2xx responses. Pass `false` to inspect headers / body of a
    ///   failed response (used by Codex, whose `x-codex-*` rate-limit headers
    ///   are emitted even on 4xx).
    static func send(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        failOnError: Bool = true
    ) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headerMap[key.lowercased()] = value
            }
        }

        if failOnError, !(200..<300).contains(http.statusCode) {
            let text = String(data: data, encoding: .utf8).map { String($0.prefix(280)) } ?? ""
            throw ProviderError.http(status: http.statusCode, body: text)
        }

        let parsed: Any? = data.isEmpty ? nil : (try? JSONSerialization.jsonObject(with: data))
        return HTTPResult(json: JSON(parsed), data: data, headers: headerMap, status: http.statusCode)
    }
}

// MARK: - JSON navigation helpers

/// Convenience subscripting for `[String: Any]` / `[Any]` trees decoded from JSON.
/// Coercion is defensive: numeric strings parse as numbers and vice-versa.
struct JSON {
    let value: Any?

    init(_ value: Any?) { self.value = value }

    subscript(key: String) -> JSON {
        JSON((value as? [String: Any])?[key])
    }

    var array: [JSON] {
        (value as? [Any])?.map(JSON.init) ?? []
    }

    var double: Double? {
        let number: Double?
        switch value {
        case let v as Double: number = v
        case let v as Int: number = Double(v)
        case let v as NSNumber: number = v.doubleValue
        case let v as String: number = Double(v)
        default: number = nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    var string: String? {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v.stringValue
        default: return nil
        }
    }
}
