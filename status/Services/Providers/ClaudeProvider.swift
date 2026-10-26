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
        let isAPIKey: Bool
        let authToken: String
        let displayName: String?

        switch request.credential {
        case let .oauth(token, _, display):
            isAPIKey = false
            authToken = token
            displayName = display
        case let .apiKey(key):
            isAPIKey = true
            authToken = key
            displayName = nil
        }

        var headers = [
            "anthropic-version": "2023-06-01",
            "user-agent": "claude-cli/2.1.119 (external, cli)",
            "Content-Type": "application/json",
        ]
        var bodyPayload: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        if isAPIKey {
            headers["x-api-key"] = authToken
        } else {
            // CLI fingerprint — the OAuth path is gated on these headers in
            // addition to the bearer token.
            headers["Authorization"] = "Bearer \(authToken)"
            headers["anthropic-beta"] = "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14,fine-grained-tool-streaming-2025-05-14"
            headers["x-app"] = "cli"
            headers["anthropic-dangerous-direct-browser-access"] = "true"
            bodyPayload["system"] = [["type": "text", "text": probeSystem]]
        }
        let body = try JSONSerialization.data(withJSONObject: bodyPayload)

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
        snapshot.planName = displayName ?? (isAPIKey ? "Anthropic API" : "Claude Code")
        snapshot.sections = Self.sections(from: result, now: now())
        // Exhausted subscriptions return 429 with the same quota headers.
        // Keep those meters, but propagate all other HTTP failures.
        if !(200..<300).contains(result.status),
           !(result.status == 429 && !snapshot.sections.isEmpty) {
            throw ProviderError.http(status: result.status, body: String(result.text.prefix(280)))
        }

        if snapshot.sections.isEmpty {
            if isAPIKey {
                snapshot.note = "Signed in via Anthropic API key. Rate limit and credit headers weren't returned on this request."
            } else {
                let status = result.header("anthropic-ratelimit-unified-status") ?? "active"
                log.notice("no rate-limit headers returned (status=\(status, privacy: .public))")
                snapshot.note = "Signed in via Claude Code (status: \(status)). The API didn't return subscription window limits on this request."
            }
        } else {
            log.info("loaded \(snapshot.sections.count) section(s)")
        }
        return snapshot
    }

    /// Maps the probe's rate-limit headers to Session / Weekly meters, falling
    /// back to the standard request/token rate-limit headers.
    static func sections(from result: HTTPResult, now: Date = Date()) -> [UsageSection] {
        var sections: [UsageSection] = []

        // 5-hour session window — `utilization` is a 0-1 fraction.
        if let session = SessionUsage.utilizationSection(
            title: "Session",
            utilization: SessionUsage.headerNumber(result, "anthropic-ratelimit-unified-5h-utilization"),
            reset: result.header("anthropic-ratelimit-unified-5h-reset"),
            now: now
        ) {
            sections.append(session)
        }

        // 7-day weekly window.
        if let weekly = SessionUsage.utilizationSection(
            title: "Weekly",
            utilization: SessionUsage.headerNumber(result, "anthropic-ratelimit-unified-7d-utilization"),
            reset: result.header("anthropic-ratelimit-unified-7d-reset"),
            now: now
        ) {
            sections.append(weekly)
        }

        // Fallback: legacy request/token rate-limit headers (API-key callers).
        if sections.isEmpty {
            if let generic = SessionUsage.limitSection(
                title: "Rate limit",
                limit: SessionUsage.headerNumber(result, "anthropic-ratelimit-requests-limit"),
                remaining: SessionUsage.headerNumber(result, "anthropic-ratelimit-requests-remaining"),
                reset: result.header("anthropic-ratelimit-requests-reset"),
                now: now
            ) {
                sections.append(generic)
            }
            if let tokens = SessionUsage.limitSection(
                title: "Tokens",
                limit: SessionUsage.headerNumber(result, "anthropic-ratelimit-tokens-limit")
                    ?? SessionUsage.headerNumber(result, "anthropic-ratelimit-input-tokens-limit"),
                remaining: SessionUsage.headerNumber(result, "anthropic-ratelimit-tokens-remaining")
                    ?? SessionUsage.headerNumber(result, "anthropic-ratelimit-input-tokens-remaining"),
                reset: result.header("anthropic-ratelimit-tokens-reset")
                    ?? result.header("anthropic-ratelimit-input-tokens-reset"),
                now: now
            ) {
                sections.append(tokens)
            }
        }
        // Extra (overage) usage, always listed when the backend reports it, like
        // Grok's "Extra Usage": a meter when enabled, "Disabled" when the org
        // turned it off (`overage-status: rejected`).
        if let extra = extraUsageSection(from: result, now: now) {
            sections.append(extra)
        }

        return sections
    }

    static func extraUsageSection(from result: HTTPResult, now: Date) -> UsageSection? {
        if let meter = SessionUsage.utilizationSection(
            title: "Extra Usage",
            utilization: SessionUsage.headerNumber(result, "anthropic-ratelimit-unified-overage-utilization"),
            reset: result.header("anthropic-ratelimit-unified-overage-reset"),
            now: now
        ) {
            return meter
        }
        guard let status = result.header("anthropic-ratelimit-unified-overage-status") else { return nil }
        let leading = status == "rejected" ? "Disabled" : "Enabled"
        return UsageSection(title: "Extra Usage", fraction: nil, leading: leading, trailing: nil)
    }
}
