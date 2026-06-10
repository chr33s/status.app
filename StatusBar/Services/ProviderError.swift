import Foundation

enum ProviderError: LocalizedError {
    case invalidResponse
    case http(status: Int, body: String)
    case decoding(String)
    case missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .http(let status, let body):
            switch status {
            case 401, 403:
                return "Authentication failed (\(status)). Check that the key is valid and has read access."
            case 404:
                return "Endpoint not found (404). The account or resource may not exist."
            case 429:
                return "Rate limited (429). Try again shortly."
            default:
                let detail = body.isEmpty ? "" : " — \(body)"
                return "Request failed (\(status))\(detail)"
            }
        case .decoding(let message):
            return "Couldn't read the response: \(message)"
        case .missingConfiguration(let message):
            return message
        }
    }
}
