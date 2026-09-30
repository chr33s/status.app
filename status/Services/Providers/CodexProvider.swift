import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.codex")

/// Codex subscription session limits, read using the **Codex CLI** login
/// (ChatGPT OAuth in `~/.codex/auth.json`, or the `Codex Auth` Keychain item
/// in keyring mode) — no API key required.
///
/// The Codex back-end emits the account's rate-limit state as **response
/// headers** on `POST /backend-api/codex/responses` (per
/// `codex-rs/codex-api/src/sse/responses.rs`):
///   • `x-codex-primary-*`
///   • `x-codex-secondary-*`
/// Each group includes `used-percent`, `window-minutes`, and `reset-at`.
/// The window duration determines whether a group is Session or Weekly; the
/// backend does not guarantee that primary and secondary keep those meanings.
/// Crucially these headers are set on the initial HTTP response — *before* the
/// SSE body is consumed and even when the body itself 4xx's (e.g. an
/// unsupported model). We therefore use a deliberately minimal probe and read
/// the headers regardless of status, falling back to a "signed in" note only
/// if no rate-limit headers are present.
struct CodexProvider: UsageProviding {
    /// Performs a POST and returns the result *without* throwing on non-2xx, so
    /// headers on a 4xx can still be read. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String], Data) async throws -> HTTPResult

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

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
        guard case let .oauth(token, accountID, displayName) = request.credential else {
            log.notice("auth.json holds an API key, not OAuth")
            return .notice(plan: "Codex CLI", "Codex is using an API key. Sign in with a ChatGPT plan (`codex`) to see session limits.")
        }

        var snapshot = UsageSnapshot()
        snapshot.planName = displayName ?? "Codex CLI"

        do {
            log.debug("probing rate_limits (accountID=\(accountID ?? "<nil>", privacy: .public))")
            let result = try await probe(token: token, accountID: accountID)
            log.debug("probe status=\(result.status)")

            // Unauthorized → let the store refresh and retry.
            if result.status == 401 || result.status == 403 {
                log.error("probe unauthorized — will refresh and retry")
                throw ProviderError.http(status: result.status, body: "")
            }

            snapshot.sections = Self.headerSections(in: result, now: now())
            if snapshot.sections.isEmpty {
                // No rate-limit headers in this response — dump everything
                // suggestive so we can diagnose which keys the backend uses.
                let suspects = result.headers
                    .filter { key, _ in
                        key.contains("rate") || key.contains("codex") || key.contains("limit")
                            || key.contains("quota") || key.contains("used")
                    }
                    .sorted { $0.key < $1.key }
                if suspects.isEmpty {
                    let body = String(result.text.prefix(400))
                        .replacingOccurrences(of: "\n", with: " ")
                    log.notice("no rate-limit headers; status=\(result.status) body=\(body, privacy: .public)")
                } else {
                    let dump = suspects.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                    log.notice("no parsed sections; suspect headers: \(dump, privacy: .public)")
                }
            } else {
                log.info("loaded \(snapshot.sections.count) section(s)")
            }
        } catch let error as ProviderError where error.isUnauthorized {
            throw error
        } catch {
            log.error("probe failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in via Codex CLI. Live session limits weren't available on this request."
        }
        return snapshot
    }

    private func probe(token: String, accountID: String?) async throws -> HTTPResult {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "OpenAI-Beta": "responses=experimental",
            "originator": "codex_cli_rs",
        ]
        if let accountID { headers["chatgpt-account-id"] = accountID }

        // The body is allowed to 4xx (unsupported model, etc.) — the
        // `x-codex-*` rate-limit headers are populated before model dispatch.
        // `store: false` is required: the ChatGPT-account responses endpoint
        // rejects requests with the default `store: true` ("Store must be set
        // to false").
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.5",
            "instructions": "ping",
            "input": [["role": "user", "content": "ping"]],
            "stream": true,
            "store": false,
        ])

        return try await transport(Self.endpoint, headers, body)
    }

    /// Builds the Codex meters, using their window duration instead of assuming
    /// the primary/secondary order. Responses without window metadata retain
    /// the legacy primary-session, secondary-weekly mapping.
    static func headerSections(in result: HTTPResult, now: Date = Date()) -> [UsageSection] {
        let limits = [
            (prefix: "x-codex-primary", fallbackTitle: "Session"),
            (prefix: "x-codex-secondary", fallbackTitle: "Weekly"),
        ]

        return limits.compactMap { limit in
            let minutes = result.header("\(limit.prefix)-window-minutes").flatMap(Double.init)
            let title = minutes.map { $0 < 24 * 60 ? "Session" : "Weekly" } ?? limit.fallbackTitle
            return headerSection(title: title, prefix: limit.prefix, in: result, now: now)
        }
        .sorted { $0.title == "Session" && $1.title != "Session" }
    }

    /// Builds a meter from one `x-codex-{primary,secondary}-*` header trio.
    static func headerSection(title: String, prefix: String, in result: HTTPResult, now: Date = Date()) -> UsageSection? {
        guard let percent = result.header("\(prefix)-used-percent").flatMap(Double.init), percent.isFinite else {
            return nil
        }
        let fraction = min(max(percent / 100, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: fraction,
            leading: Format.percentUsed(fraction),
            trailing: nil
        )
        if let resetAt = result.header("\(prefix)-reset-at"),
           let date = SessionUsage.resetDate(from: resetAt, now: now) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }
}
