import Foundation

/// Claude subscription session limits, read using the **Claude Code** login
/// (OAuth) — no API key required.
///
/// Approach: issue a free `POST /v1/messages/count_tokens` probe with the OAuth
/// bearer token. Anthropic returns the account's unified rate-limit state in the
/// response headers, which we map to the "Session" (5h) and "Weekly" (7d) meters
/// shown in the menu.
///
/// ── Verify on a real Mac ──
/// The unified-limit header names below are based on Anthropic's observed
/// `anthropic-ratelimit-unified-*` headers and may evolve. They are isolated
/// here so they're trivial to adjust. If none are present we fall back to the
/// standard request/token rate-limit headers.
struct ClaudeProvider: UsageProviding {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
    private let probeModel = "claude-3-5-haiku-20241022"

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _) = request.credential else {
            throw ProviderError.missingConfiguration("No Claude Code login found.")
        }

        let headers = [
            "Authorization": "Bearer \(token)",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "model": probeModel,
            "messages": [["role": "user", "content": "ping"]],
        ])

        let result = try await HTTPClient.send(endpoint, method: "POST", headers: headers, body: body)

        var snapshot = UsageSnapshot()
        snapshot.planName = "Claude Code"

        // 5-hour session window.
        if let session = SessionUsage.limitSection(
            title: "Session",
            limit: number(result, "anthropic-ratelimit-unified-5h-limit"),
            remaining: number(result, "anthropic-ratelimit-unified-5h-remaining"),
            reset: result.header("anthropic-ratelimit-unified-5h-reset")
        ) {
            snapshot.sections.append(session)
        }

        // 7-day weekly window.
        if let weekly = SessionUsage.limitSection(
            title: "Weekly",
            limit: number(result, "anthropic-ratelimit-unified-7d-limit"),
            remaining: number(result, "anthropic-ratelimit-unified-7d-remaining"),
            reset: result.header("anthropic-ratelimit-unified-7d-reset")
        ) {
            snapshot.sections.append(weekly)
        }

        // Opus-specific weekly window (shown by Claude for Max plans).
        if let opus = SessionUsage.limitSection(
            title: "Opus (Weekly)",
            limit: number(result, "anthropic-ratelimit-unified-7d-opus-limit"),
            remaining: number(result, "anthropic-ratelimit-unified-7d-opus-remaining"),
            reset: result.header("anthropic-ratelimit-unified-7d-opus-reset")
        ) {
            snapshot.sections.append(opus)
        }

        // Fallback: generic unified or standard request limits.
        if snapshot.sections.isEmpty,
           let generic = SessionUsage.limitSection(
               title: "Rate limit",
               limit: number(result, "anthropic-ratelimit-unified-limit")
                   ?? number(result, "anthropic-ratelimit-requests-limit"),
               remaining: number(result, "anthropic-ratelimit-unified-remaining")
                   ?? number(result, "anthropic-ratelimit-requests-remaining"),
               reset: result.header("anthropic-ratelimit-unified-reset")
                   ?? result.header("anthropic-ratelimit-requests-reset")
           ) {
            snapshot.sections.append(generic)
        }

        if snapshot.sections.isEmpty {
            let status = result.header("anthropic-ratelimit-unified-status") ?? "active"
            snapshot.note = "Signed in via Claude Code (status: \(status)). The API didn't return subscription window limits on this request."
        }
        return snapshot
    }

    private func number(_ result: HTTPResult, _ name: String) -> Double? {
        result.header(name).flatMap(Double.init)
    }
}
