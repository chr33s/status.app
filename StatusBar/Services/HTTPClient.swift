import Foundation

/// Minimal async HTTP helper. Returns parsed JSON (as `Any`) so providers can
/// navigate response shapes defensively without brittle Codable models.
enum HTTPClient {
    static func getJSON(_ url: URL, headers: [String: String]) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8).map { String($0.prefix(280)) } ?? ""
            throw ProviderError.http(status: http.statusCode, body: body)
        }
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
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

    subscript(index: Int) -> JSON {
        guard let array = value as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    var array: [JSON] {
        (value as? [Any])?.map(JSON.init) ?? []
    }

    var double: Double? {
        switch value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }

    var string: String? {
        switch value {
        case let v as String: return v
        case let v as NSNumber: return v.stringValue
        default: return nil
        }
    }
}
