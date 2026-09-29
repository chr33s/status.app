import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.copilot")

/// GitHub Copilot usage via the **Copilot CLI** / gh login (OAuth token in the
/// `copilot-cli` or `gh:github.com` Keychain item, or the legacy
/// `~/.config/github-copilot/apps.json`) — no API key.
///
/// Uses GitHub's internal entitlement endpoint `GET /copilot_internal/user`,
/// which works with the `repo`/`workflow`-scoped Copilot CLI token (the public
/// billing API requires `manage_billing:copilot`, which CLI tokens don't have).
///
/// ── Verify on a real Mac ──
/// `copilot_internal` is undocumented and the request must look like a real
/// Copilot client — GitHub rejects unknown User-Agents on this namespace. The
/// `quota_snapshots.premium_interactions` block is the same number the CLI's
/// `/usage` command displays.
struct CopilotProvider: UsageProviding {
    /// Performs a GET and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String]) async throws -> HTTPResult

    static let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers in try await HTTPClient.send(url, headers: headers) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, accountID, displayName) = request.credential else {
            log.error("missing OAuth credential")
            throw ProviderError.missingConfiguration("No Copilot CLI login found.")
        }
        let headers = [
            // Internal endpoint expects the `token` scheme, not `Bearer`, and a
            // recognised Copilot client identity.
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "Editor-Version": "vscode/1.104.3",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
        ]

        log.debug("fetching copilot_internal/user")
        let result: HTTPResult
        do {
            result = try await transport(Self.endpoint, headers)
        } catch {
            log.error("copilot_internal/user failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let json = result.json

        var snapshot = UsageSnapshot()
        snapshot.planName = displayName ?? accountID ?? json["copilot_plan"].string ?? "Copilot"

        snapshot.sections = Self.sections(from: json, now: now())

        if snapshot.sections.isEmpty {
            log.notice("no quota_snapshots returned")
            snapshot.note = "Signed in via Copilot CLI. No quota was returned for this account."
        } else {
            log.info("loaded \(snapshot.sections.count) section(s) (plan=\(json["copilot_plan"].string ?? "?", privacy: .public))")
        }
        return snapshot
    }

    /// Maps `quota_snapshots` to meters. The CLI surfaces `premium_interactions`
    /// as "Premium requests"; chat and completions follow the same shape.
    static func sections(from json: JSON, now: Date = Date()) -> [UsageSection] {
        let reset = json["quota_reset_date"].string.flatMap(parseResetDate(_:))
        let quotas = json["quota_snapshots"]
        return [
            ("premium_interactions", "Premium requests"),
            ("chat", "Chat"),
            ("completions", "Completions"),
        ].compactMap { key, title in
            quotaSection(quotas[key], title: title, reset: reset, now: now)
        }
    }

    private static func quotaSection(_ bucket: JSON, title: String, reset: Date?, now: Date) -> UsageSection? {
        // `unlimited: true` plans get a friendlier row with no meter.
        if bucket["unlimited"].value as? Bool == true {
            return UsageSection(title: title, fraction: nil, leading: "Unlimited", trailing: nil)
        }
        guard let entitlement = bucket["entitlement"].double, entitlement > 0,
              let remaining = bucket["remaining"].double else { return nil }
        let used = min(max(1 - remaining / entitlement, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: used,
            leading: "\(Int(remaining.rounded())) / \(Int(entitlement.rounded())) left",
            trailing: nil
        )
        if let reset { section.trailing = Format.resetCountdown(to: reset, now: now) }
        return section
    }

    /// `quota_reset_date` is a plain `YYYY-MM-DD` string in UTC.
    private static func parseResetDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
