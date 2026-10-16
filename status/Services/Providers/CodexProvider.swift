import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.codex")

/// Codex subscription session limits, read using the **Codex CLI** login
/// (ChatGPT OAuth in `~/.codex/auth.json`, or the `Codex Auth` Keychain item
/// in keyring mode) — no API key required.
///
/// Reads `GET /backend-api/wham/usage`, the endpoint the Codex CLI's own
/// `/status` command uses. Its `rate_limit` object carries a `primary_window`
/// and a `secondary_window`, each `{ used_percent, limit_window_seconds,
/// reset_after_seconds, reset_at }`; either may be `null` when the plan has a
/// single window. The window length decides whether a meter is Session or
/// Weekly — the backend does not guarantee that primary and secondary keep
/// those meanings.
///
/// Earlier builds probed `POST /backend-api/codex/responses` for its
/// `x-codex-*` headers, but the backend now rejects unknown models *before*
/// attaching those headers, and the usable model list moves between releases.
/// `wham/usage` needs no model and spends no quota.
struct CodexProvider: UsageProviding {
    /// Performs a GET and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String]) async throws -> HTTPResult

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers in
            try await HTTPClient.send(url, headers: headers)
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

        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "codex_cli_rs",
            "originator": "codex_cli_rs",
        ]
        if let accountID { headers["chatgpt-account-id"] = accountID }

        log.debug("fetching usage (accountID=\(accountID ?? "<nil>", privacy: .public))")
        let result: HTTPResult
        do {
            // 401/403 propagate as-is so the store can refresh and retry;
            // other failures propagate so the last good usage stays visible.
            result = try await transport(Self.endpoint, headers)
        } catch {
            log.error("usage request failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        snapshot.sections = Self.sections(in: result.json, now: now())
        if snapshot.sections.isEmpty {
            let body = String(result.text.prefix(400)).replacingOccurrences(of: "\n", with: " ")
            log.notice("no rate-limit windows; status=\(result.status) body=\(body, privacy: .public)")
            snapshot.note = "Signed in via Codex CLI. Live session limits weren't available on this request."
        } else {
            log.info("loaded \(snapshot.sections.count) section(s)")
        }
        return snapshot
    }

    /// Builds the Codex meters from a `wham/usage` body, titled by window
    /// length rather than by primary/secondary position. Windows that are
    /// null, lack `used_percent`, or have a zero-length window (the backend's
    /// "no such limit" placeholder) are skipped.
    static func sections(in json: JSON, now: Date = Date()) -> [UsageSection] {
        let limit = json["rate_limit"]
        let windows = [
            (json: limit["primary_window"], fallbackTitle: "Session"),
            (json: limit["secondary_window"], fallbackTitle: "Weekly"),
        ]
        return windows.compactMap { window in
            SessionUsage.windowSection(window.json, fallbackTitle: window.fallbackTitle, now: now)
        }
        .sorted { $0.title == "Session" && $1.title != "Session" }
    }
}
