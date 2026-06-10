import Foundation

/// Codex subscription session limits, read using the **Codex CLI** login
/// (ChatGPT OAuth in `~/.codex/auth.json`) — no API key required.
///
/// The Codex back-end returns a `rate_limits` object with `primary` (≈5h
/// "Session") and `secondary` (≈weekly) windows, each of the shape
/// `{ used_percent, window_minutes, resets_in_seconds }`. We surface those as
/// meters.
///
/// ── Verify on a real Mac ──
/// The endpoint and headers used to obtain `rate_limits` are isolated in
/// `fetchRateLimits` and are based on the Codex CLI's observed traffic; adjust
/// there if the CLI changes. Any failure degrades to a friendly "signed in"
/// note rather than an error.
struct CodexProvider: UsageProviding {
    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, accountID) = request.credential else {
            // auth.json held an API key, not a ChatGPT login — session limits
            // aren't available without the subscription token.
            var snapshot = UsageSnapshot()
            snapshot.planName = "Codex CLI"
            snapshot.note = "Codex is using an API key. Sign in with a ChatGPT plan (`codex`) to see session limits."
            return snapshot
        }

        var snapshot = UsageSnapshot()
        snapshot.planName = "Codex CLI"

        do {
            let limits = try await fetchRateLimits(token: token, accountID: accountID)
            if let primary = SessionUsage.windowSection(title: "Session", limits["primary"]) {
                snapshot.sections.append(primary)
            }
            if let secondary = SessionUsage.windowSection(title: "Weekly", limits["secondary"]) {
                snapshot.sections.append(secondary)
            }
        } catch let error as ProviderError where error.isUnauthorized {
            // Let the store refresh the token and retry.
            throw error
        } catch {
            // Other failures shouldn't blank the tab — show a note instead.
        }

        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in via Codex CLI. Live session limits weren't available on this request."
        }
        return snapshot
    }

    /// Requests the current `rate_limits` snapshot for the signed-in ChatGPT
    /// account. The Codex back-end replies with a Server-Sent Events stream; the
    /// `rate_limits` object is carried inside one of the events (typically
    /// `response.completed`), so we scan every `data:` payload for it.
    private func fetchRateLimits(token: String, accountID: String?) async throws -> JSON {
        let url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
        ]
        if let accountID { headers["chatgpt-account-id"] = accountID }

        // Minimal streamed probe; the stream carries the account's rate_limits.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-codex",
            "input": [["role": "user", "content": "ping"]],
            "max_output_tokens": 1,
            "stream": true,
        ])

        let result = try await HTTPClient.send(url, method: "POST", headers: headers, body: body)
        return Self.rateLimits(fromSSE: result.text) ?? result.json["rate_limits"]
    }

    /// Parses an SSE body, returning the first `rate_limits` object found in any
    /// event payload.
    static func rateLimits(fromSSE text: String) -> JSON? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let found = findRateLimits(object) { return JSON(found) }
        }
        return nil
    }

    /// Depth-first search for a `rate_limits` key anywhere in a JSON tree.
    private static func findRateLimits(_ any: Any?) -> Any? {
        if let dict = any as? [String: Any] {
            if let value = dict["rate_limits"] { return value }
            for value in dict.values {
                if let found = findRateLimits(value) { return found }
            }
        } else if let array = any as? [Any] {
            for value in array {
                if let found = findRateLimits(value) { return found }
            }
        }
        return nil
    }
}
