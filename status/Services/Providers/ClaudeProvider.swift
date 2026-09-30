import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.claude")

/// Claude subscription session limits, read using the **Claude Code** login
/// (OAuth) — no API key required.
///
/// Approach: issue a minimal `POST /v1/messages` probe (`max_tokens: 1`) with
/// the OAuth bearer token. Anthropic returns the account's unified rate-limit
/// state in the response headers, which we map to the "Session" (5h) and
/// "Weekly" (7d) meters shown in the menu.
///
/// ── Verify on a real Mac ──
/// The Claude Code OAuth tokens are scoped to `/v1/messages` only — other
/// endpoints return 404 — and the `oauth-2025-04-20` beta requires the Claude
/// Code identity in the system prompt plus the CLI fingerprint headers below.
/// The unified-limit header names now follow the
/// `anthropic-ratelimit-unified-{5h,7d}-{status,utilization,reset}` shape
/// (utilization is a 0-1 fraction, not a token count). If none are present we
/// fall back to the standard request/token rate-limit headers.
struct ClaudeProvider: UsageProviding {
    /// Performs a POST and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String], Data) async throws -> HTTPResult

    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// Haiku 4.5 — the cheapest model the OAuth path currently accepts.
    /// Older dated Haiku 3.5 IDs return `not_found_error` (404) on OAuth.
    private let probeModel = "claude-haiku-4-5"
    /// The first system block MUST start with this exact string; Anthropic's
    /// OAuth allow-list keys off it.
    private let probeSystem = "You are Claude Code, Anthropic's official CLI for Claude."

    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers, body in
            try await HTTPClient.send(url, method: "POST", headers: headers, body: body, failOnError: false)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _, displayName) = request.credential else {
            log.error("missing OAuth credential")
            throw ProviderError.missingConfiguration("No Claude Code login found.")
        }

        // CLI fingerprint — the OAuth path is gated on these headers in
        // addition to the bearer token.
        let headers = [
            "Authorization": "Bearer \(token)",
            "anthropic-version": "2023-06-01",
            "anthropic-beta": "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14",
            "user-agent": "claude-cli/2.1.119 (external, cli)",
            "x-app": "cli",
            "anthropic-dangerous-direct-browser-access": "true",
            "Content-Type": "application/json",
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "model": probeModel,
            "max_tokens": 1,
            "system": [["type": "text", "text": probeSystem]],
            "messages": [["role": "user", "content": "ping"]],
        ])

        log.debug("probing \(Self.endpoint.absoluteString, privacy: .public)")
        let result: HTTPResult
        do {
            result = try await transport(Self.endpoint, headers, body)
        } catch {
            log.error("probe failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        log.debug("probe ok status=\(result.status)")

        var snapshot = UsageSnapshot()
        snapshot.planName = displayName ?? "Claude Code"
        snapshot.sections = Self.sections(from: result, now: now())
        // Exhausted subscriptions return 429 with the same quota headers.
        // Keep those meters, but propagate all other HTTP failures.
        if !(200..<300).contains(result.status),
           !(result.status == 429 && !snapshot.sections.isEmpty) {
            throw ProviderError.http(status: result.status, body: String(result.text.prefix(280)))
        }

        if snapshot.sections.isEmpty {
            let status = result.header("anthropic-ratelimit-unified-status") ?? "active"
            log.notice("no rate-limit headers returned (status=\(status, privacy: .public))")
            snapshot.note = "Signed in via Claude Code (status: \(status)). The API didn't return subscription window limits on this request."
        } else {
            log.info("loaded \(snapshot.sections.count) section(s)")
        }
        return snapshot
    }

    /// Maps the probe's rate-limit headers to Session / Weekly meters, falling
    /// back to the legacy request limit when no unified headers are present.
    static func sections(from result: HTTPResult, now: Date = Date()) -> [UsageSection] {
        var sections: [UsageSection] = []

        // 5-hour session window — `utilization` is a 0-1 fraction.
        if let session = SessionUsage.utilizationSection(
            title: "Session",
            utilization: number(result, "anthropic-ratelimit-unified-5h-utilization"),
            reset: result.header("anthropic-ratelimit-unified-5h-reset"),
            now: now
        ) {
            sections.append(session)
        }

        // 7-day weekly window.
        if let weekly = SessionUsage.utilizationSection(
            title: "Weekly",
            utilization: number(result, "anthropic-ratelimit-unified-7d-utilization"),
            reset: result.header("anthropic-ratelimit-unified-7d-reset"),
            now: now
        ) {
            sections.append(weekly)
        }

        // Fallback: legacy request/token rate-limit headers (API-key callers).
        if sections.isEmpty,
           let generic = SessionUsage.limitSection(
               title: "Rate limit",
               limit: number(result, "anthropic-ratelimit-requests-limit"),
               remaining: number(result, "anthropic-ratelimit-requests-remaining"),
               reset: result.header("anthropic-ratelimit-requests-reset"),
               now: now
           ) {
            sections.append(generic)
        }
        return sections
    }

    private static func number(_ result: HTTPResult, _ name: String) -> Double? {
        result.header(name).flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
    }
}
