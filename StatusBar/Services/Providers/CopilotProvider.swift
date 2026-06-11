import Foundation
import os

private let log = Logger(subsystem: "app.statusbar", category: "provider.copilot")

/// GitHub Copilot usage via the **Copilot CLI** login (OAuth token at
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
    private let endpoint = URL(string: "https://api.github.com/copilot_internal/user")!

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
            result = try await HTTPClient.send(endpoint, headers: headers)
        } catch {
            log.error("copilot_internal/user failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let json = result.json

        var snapshot = UsageSnapshot()
        snapshot.planName = displayName ?? accountID ?? json["copilot_plan"].string ?? "Copilot"

        let reset = json["quota_reset_date"].string.flatMap(Self.parseResetDate(_:))

        // The CLI surfaces `premium_interactions` as "Premium requests"; chat
        // and completions follow the same shape.
        appendQuota(json["quota_snapshots"]["premium_interactions"], title: "Premium requests", reset: reset, into: &snapshot)
        appendQuota(json["quota_snapshots"]["chat"], title: "Chat", reset: reset, into: &snapshot)
        appendQuota(json["quota_snapshots"]["completions"], title: "Completions", reset: reset, into: &snapshot)

        if snapshot.sections.isEmpty {
            log.notice("no quota_snapshots returned")
            snapshot.note = "Signed in via Copilot CLI. No quota was returned for this account."
        } else {
            log.info("loaded \(snapshot.sections.count) section(s) (plan=\(json["copilot_plan"].string ?? "?", privacy: .public))")
        }
        return snapshot
    }

    private func appendQuota(_ bucket: JSON, title: String, reset: Date?, into snapshot: inout UsageSnapshot) {
        // `unlimited: true` plans get a friendlier row with no meter.
        if bucket["unlimited"].value as? Bool == true {
            snapshot.sections.append(UsageSection(
                title: title, fraction: nil, leading: "Unlimited", trailing: nil
            ))
            return
        }
        guard let entitlement = bucket["entitlement"].double, entitlement > 0,
              let remaining = bucket["remaining"].double else { return }
        let used = min(max(1 - remaining / entitlement, 0), 1)
        var section = UsageSection(
            title: title,
            fraction: used,
            leading: "\(Int(remaining.rounded())) / \(Int(entitlement.rounded())) left",
            trailing: nil
        )
        if let reset { section.trailing = Format.resetCountdown(to: reset) }
        snapshot.sections.append(section)
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
