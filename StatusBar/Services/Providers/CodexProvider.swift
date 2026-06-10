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

        if let limits = try? await fetchRateLimits(token: token, accountID: accountID) {
            if let primary = SessionUsage.windowSection(title: "Session", limits["primary"]) {
                snapshot.sections.append(primary)
            }
            if let secondary = SessionUsage.windowSection(title: "Weekly", limits["secondary"]) {
                snapshot.sections.append(secondary)
            }
        }

        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in via Codex CLI. Live session limits weren't available on this request."
        }
        return snapshot
    }

    /// Requests the current `rate_limits` snapshot for the signed-in ChatGPT
    /// account. Returns the JSON `rate_limits` object.
    private func fetchRateLimits(token: String, accountID: String?) async throws -> JSON {
        let url = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
        ]
        if let accountID { headers["chatgpt-account-id"] = accountID }

        // Minimal probe; the response carries the account's rate_limits.
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5-codex",
            "input": [["role": "user", "content": "ping"]],
            "max_output_tokens": 1,
            "stream": false,
        ])

        let result = try await HTTPClient.send(url, method: "POST", headers: headers, body: body)
        // `rate_limits` may sit at the top level or under `response`.
        let direct = result.json["rate_limits"]
        if direct.value != nil { return direct }
        return result.json["response"]["rate_limits"]
    }
}
