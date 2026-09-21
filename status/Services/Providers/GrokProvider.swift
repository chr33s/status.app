import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.grok")

/// xAI Grok subscription usage via the **Grok CLI** OIDC login
/// (`~/.grok/auth.json`), read from the same billing endpoint the CLI uses.
///
/// - `GET /v1/billing?format=credits` → weekly shared-pool percent, reset time,
///   and the pay-as-you-go cap.
/// - `GET /v1/settings` → `subscription_tier_display` as the plan label
///   (best-effort; a failure here never discards billing usage).
///
/// Live token/cost data is tracked separately via OpenTelemetry metrics that
/// the Grok CLI emits — see `OTelMetricsParser`.
///
/// A 401/403 surfaces as `ProviderError.http`, which drives the store's
/// refresh-and-retry path.
struct GrokProvider: UsageProviding {
    /// Performs a GET and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String]) async throws -> HTTPResult

    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let settingsURL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!

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
        guard case let .oauth(token, _, displayName) = request.credential else {
            log.notice("no OIDC credential (API key only)")
            return .notice(plan: "Grok CLI",
                "Grok is using an API key, which has no quota endpoint. Sign in with `grok login` to track subscription usage.")
        }
        let payload = Self.decodeJWT(token)
        // Catch expired tokens locally so the store refreshes instead of
        // failing the request remotely.
        if let exp = payload["exp"].flatMap(Self.asTimestamp), exp < now() {
            log.error("access token expired locally")
            throw ProviderError.http(status: 401, body: "token expired")
        }

        let headers = Self.headers(token: token)

        let billing: HTTPResult
        do {
            billing = try await transport(Self.billingURL, headers)
        } catch {
            log.error("billing failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        var snapshot = UsageSnapshot()
        snapshot.sections = try Self.parseBilling(billing.json, now: now())

        // Plan label is non-fatal: billing already succeeded.
        do {
            let settings = try await transport(Self.settingsURL, headers)
            snapshot.planName = Self.parsePlanName(settings.json)
        } catch {
            log.notice("settings failed: \(error.localizedDescription, privacy: .public)")
        }
        if snapshot.planName == nil {
            snapshot.planName = (payload["tier"] as? Int).map { "Grok Tier \($0)" }
                ?? displayName
                ?? "Grok CLI"
        }
        return snapshot
    }

    static func headers(token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-XAI-Token-Auth": "xai-grok-cli",
            "Accept": "application/json",
        ]
    }

    /// Maps a `/v1/billing?format=credits` response to meters. The Weekly meter
    /// is shown only for weekly periods so another billing period is never
    /// mislabelled; Extra Usage is always shown.
    static func parseBilling(_ json: JSON, now: Date = Date()) throws -> [UsageSection] {
        let config = json["config"]
        guard config.value is [String: Any] else {
            throw ProviderError.decoding("the Grok billing response changed (missing `config`).")
        }

        var sections: [UsageSection] = []
        let period = config["currentPeriod"]
        if period["type"].string == "USAGE_PERIOD_TYPE_WEEKLY" {
            let fraction = min(max((config["creditUsagePercent"].double ?? 0) / 100, 0), 1)
            var weekly = UsageSection(
                title: "Weekly",
                fraction: fraction,
                leading: Format.percentUsed(fraction),
                trailing: nil
            )
            if let end = resetDate(period["end"].string) {
                weekly.trailing = Format.resetCountdown(to: end, now: now)
            }
            sections.append(weekly)
        }

        let cap = config["onDemandCap"]["val"].double ?? 0
        sections.append(UsageSection(
            title: "Extra Usage",
            fraction: nil,
            leading: cap > 0 ? "\(Int(cap.rounded())) cap" : "Disabled",
            trailing: nil
        ))
        return sections
    }

    /// `subscription_tier_display` from `/v1/settings`, if present.
    static func parsePlanName(_ json: JSON) -> String? {
        guard let tier = json["subscription_tier_display"].string, !tier.isEmpty else { return nil }
        return tier
    }

    /// ISO-8601 with or without fractional seconds, or an epoch.
    private static func resetDate(_ raw: String?) -> Date? {
        if let date = SessionUsage.resetDate(from: raw) { return date }
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// Decodes a JWT's payload claims without signature verification (the token
    /// is already trusted — we only read claims).
    static func decodeJWT(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload.append(String(repeating: "=", count: (4 - payload.count % 4) % 4))
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private static func asTimestamp(_ any: Any) -> Date? {
        switch any {
        case let v as Double: return Date(timeIntervalSince1970: v)
        case let v as Int: return Date(timeIntervalSince1970: Double(v))
        case let v as NSNumber: return Date(timeIntervalSince1970: v.doubleValue)
        default: return nil
        }
    }
}
