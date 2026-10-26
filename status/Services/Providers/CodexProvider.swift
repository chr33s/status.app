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
    /// API-key callers: the dashboard billing endpoints reject secret keys
    /// (browser session only) and `/v1/models` carries no rate-limit headers,
    /// so a 1-token completion is the only source of limits.
    static let probeURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private let probeModel = "gpt-5-nano"

    /// POST used by the API-key probe. Injectable for tests.
    typealias Probe = @Sendable (URL, [String: String], Data) async throws -> HTTPResult

    private let transport: Transport
    private let probe: Probe
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers in
            try await HTTPClient.send(url, headers: headers)
        },
        probe: @escaping Probe = { url, headers, body in
            try await HTTPClient.send(url, method: "POST", headers: headers, body: body, failOnError: false)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.probe = probe
        self.now = now
    }

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        switch request.credential {
        case let .oauth(token, accountID, displayName):
            return try await fetchOAuth(token: token, accountID: accountID, displayName: displayName)
        case let .apiKey(key):
            return try await fetchAPIKey(key: key)
        }
    }

    private func fetchOAuth(token: String, accountID: String?, displayName: String?) async throws -> UsageSnapshot {
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

    private func fetchAPIKey(key: String) async throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.planName = "OpenAI API"

        let headers = [
            "Authorization": "Bearer \(key)",
            "Content-Type": "application/json",
            "User-Agent": "status-app/1.0",
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "model": probeModel,
            "max_completion_tokens": 16,
            "messages": [["role": "user", "content": "ping"]],
        ])
        let result = try await probe(Self.probeURL, headers, body)
        let sections = SessionUsage.openAIRateLimitSections(result, now: now())
        // An exhausted key (429) still reports its limits; other failures don't.
        if !(200..<300).contains(result.status), !(result.status == 429 && !sections.isEmpty) {
            throw ProviderError.http(status: result.status, body: String(result.text.prefix(280)))
        }

        snapshot.sections = sections
        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in with OpenAI API key. The API returned no rate-limit headers."
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
        var list = windows.compactMap { window in
            SessionUsage.windowSection(window.json, fallbackTitle: window.fallbackTitle, now: now)
        }
        .sorted { $0.title == "Session" && $1.title != "Session" }

        list.append(contentsOf: extraUsageSections(in: json))
        return list
    }

    /// Extra-usage rows from `wham/usage`: the purchased-credit balance and the
    /// workspace spend control. Like Grok's "Extra Usage", each is listed with a
    /// status ("No credits", "Not set") whenever the backend reports the object,
    /// and omitted only when the plan's response lacks it.
    static func extraUsageSections(in json: JSON) -> [UsageSection] {
        var list: [UsageSection] = []
        let credits = json["credits"]
        if credits.value != nil {
            let balance = credits["balance"].double ?? 0
            let leading: String
            if credits["unlimited"].bool == true {
                leading = "Unlimited"
            } else if balance > 0 {
                leading = String(format: "%g credits", balance)
            } else {
                leading = "No credits"
            }
            list.append(UsageSection(
                title: "Credits",
                fraction: nil,
                leading: leading,
                trailing: credits["overage_limit_reached"].bool == true ? "Limit reached" : nil
            ))
        }

        let control = json["spend_control"]
        if control.value != nil {
            let limit = control["individual_limit"].double
            let reached = control["reached"].bool == true
            list.append(UsageSection(
                title: "Spend Limit",
                fraction: reached ? 1 : nil,
                leading: limit.map { String(format: "%g limit", $0) } ?? (reached ? "Limit set" : "Not set"),
                trailing: reached ? "Reached" : nil
            ))
        }
        return list
    }
}
