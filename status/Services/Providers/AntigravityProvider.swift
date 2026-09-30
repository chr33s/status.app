import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.antigravity")

/// Antigravity (Google's AI IDE) usage via the OAuth login the Antigravity app /
/// `agy` CLI keeps in the Keychain — no API key.
///
/// Mirrors openusage's Cloud Code strategy:
///  1. `retrieveUserQuotaSummary` — the authoritative source: two shared pools
///     (Gemini, and every non-Gemini model shown as "Claude"), each with a
///     rolling 5-hour and a weekly window.
///  2. Builds without that endpoint fall back to `loadCodeAssist` +
///     `retrieveUserQuota`, whose per-model buckets are merged into the two
///     pools by keeping each pool's worst remaining fraction (5-hour only).
///
/// ── Verify on a real Mac ──
/// These are `v1internal` (undocumented) endpoints reverse-engineered from the
/// Antigravity app; shapes are isolated here. Each call tries the daily base
/// first, then production: accounts metered on the daily deployment get a
/// "no window open" sentinel (100% remaining) from production, so daily must
/// win. Only a 401 is propagated so the store can refresh — this API answers
/// 403 "You do not have a valid license" to well-authenticated requests it
/// merely dislikes (e.g. quota calls without `project`), which must not be
/// surfaced as an expired session.
struct AntigravityProvider: UsageProviding {
    /// Performs a POST and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String], Data) async throws -> HTTPResult

    static let baseURLs = [
        URL(string: "https://daily-cloudcode-pa.googleapis.com")!,
        URL(string: "https://cloudcode-pa.googleapis.com")!,
    ]
    static let summaryPath = "v1internal:retrieveUserQuotaSummary"
    static let loadPath = "v1internal:loadCodeAssist"
    static let quotaPath = "v1internal:retrieveUserQuota"

    /// Quota-summary buckets matched by exact `bucketId`, in display order. An
    /// unknown future bucket never silently joins a pool.
    static let summaryBuckets: [(id: String, title: String)] = [
        ("gemini-5h", "Session"),
        ("gemini-weekly", "Weekly"),
        ("3p-5h", "Claude"),
        ("3p-weekly", "Claude Weekly"),
    ]

    private let transport: Transport
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers, body in
            try await HTTPClient.send(url, method: "POST", headers: headers, body: body)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _, displayName) = request.credential else {
            return .notice(plan: "Antigravity", "Antigravity has no API-key usage endpoint. Open Antigravity or run `agy` to sign in.")
        }

        let loadBody: [String: Any] = [
            "metadata": [
                "ideType": "ANTIGRAVITY",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        let load = try await call(Self.loadPath, token: token, userAgent: "antigravity", body: loadBody)
        var snapshot = UsageSnapshot()
        snapshot.planName = load.flatMap { Self.plan(from: $0.json) } ?? displayName ?? "Antigravity"

        let now = now()
        // Both quota endpoints are project-scoped: without `project` they answer
        // 403 "You do not have a valid license" even for a valid, licensed login.
        let project = load?.json["cloudaicompanionProject"].string.flatMap { $0.isEmpty ? nil : $0 }
        let quotaBody: [String: Any] = project.map { ["project": $0] } ?? [:]

        if let summary = try await call(Self.summaryPath, token: token, userAgent: "antigravity", body: quotaBody),
           let sections = Self.summarySections(in: summary.json, now: now) {
            // A parsed summary — even an empty one — is authoritative; the legacy
            // path would fabricate "fully used" from missing quota info.
            snapshot.sections = sections
        } else {
            log.debug("no quota summary; falling back to retrieveUserQuota")
            let quota = try await call(Self.quotaPath, token: token, userAgent: "antigravity", body: quotaBody)
            snapshot.sections = quota.map { Self.legacySections(in: $0.json, now: now) } ?? []
        }
        log.info("loaded \(snapshot.sections.count) quota section(s)")
        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in to Antigravity. No quota was returned for this account."
        }
        return snapshot
    }

    /// POSTs `path` against each base URL in turn. A 401 (expired/revoked
    /// token) propagates so the store can refresh — the same token fails
    /// everywhere. Everything else, including this API's 403 licensing
    /// response, tries the next base and finally yields nil so the caller
    /// falls back instead of demanding a needless re-auth.
    private func call(_ path: String, token: String, userAgent: String, body: [String: Any]) async throws -> HTTPResult? {
        let payload = try JSONSerialization.data(withJSONObject: body)
        let headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": userAgent,
        ]
        for base in Self.baseURLs {
            do {
                return try await transport(base.appendingPathComponent(path), headers, payload)
            } catch let error as ProviderError {
                if case let .http(status, message) = error, status == 401 {
                    log.error("\(path, privacy: .public) unauthorized on \(base.host() ?? "", privacy: .public): \(message, privacy: .public)")
                    throw error
                }
                log.notice("\(path, privacy: .public) failed on \(base.host() ?? "", privacy: .public): \(error.localizedDescription, privacy: .public)")
            } catch {
                log.notice("\(path, privacy: .public) failed on \(base.host() ?? "", privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: Parsing

    /// `retrieveUserQuotaSummary` → up to four pool sections. Nil when the body
    /// has no `groups` (not a summary). Buckets without a usable
    /// `remainingFraction` are dropped rather than guessed.
    static func summarySections(in json: JSON, now: Date = Date()) -> [UsageSection]? {
        let root = json["response"]["groups"].value == nil ? json : json["response"]
        guard root["groups"].value != nil else { return nil }
        var pooled: [String: JSON] = [:]
        for bucket in root["groups"].array.flatMap(\.["buckets"].array) {
            guard let id = bucket["bucketId"].string, pooled[id] == nil,
                  bucket["remainingFraction"].double != nil else { continue }
            pooled[id] = bucket
        }
        return summaryBuckets.compactMap { spec in
            pooled[spec.id].map { section(title: spec.title, remaining: $0["remainingFraction"].double ?? 0,
                                          reset: $0["resetTime"].string, now: now) }
        }
    }

    /// Legacy `retrieveUserQuota` buckets merged into the Gemini ("Session") and
    /// non-Gemini ("Claude") 5-hour pools, worst remaining fraction wins. A
    /// bucket with no fraction is treated as depleted, matching openusage.
    static func legacySections(in json: JSON, now: Date = Date()) -> [UsageSection] {
        var pooled: [String: (remaining: Double, reset: String?)] = [:]
        for bucket in json["buckets"].array {
            guard let model = bucket["modelId"].string, !model.isEmpty else { continue }
            let pool = model.lowercased().contains("gemini") ? "Session" : "Claude"
            let remaining = bucket["remainingFraction"].double ?? 0
            if let existing = pooled[pool], existing.remaining <= remaining { continue }
            pooled[pool] = (remaining, bucket["resetTime"].string)
        }
        return ["Session", "Claude"].compactMap { title in
            pooled[title].map { section(title: title, remaining: $0.remaining, reset: $0.reset, now: now) }
        }
    }

    static func section(title: String, remaining: Double, reset: String?, now: Date = Date()) -> UsageSection {
        let used = min(max(1 - remaining, 0), 1)
        var section = UsageSection(title: title, fraction: used, leading: Format.percentUsed(used), trailing: nil)
        if let date = SessionUsage.resetDate(from: reset, now: now) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }

    /// `loadCodeAssist` tier → short plan label ("Gemini Code Assist in Google
    /// One AI Pro" → "Antigravity Pro"). Paid tier preferred over current tier.
    static func plan(from json: JSON) -> String? {
        guard let raw = json["paidTier"]["name"].string ?? json["currentTier"]["name"].string,
              !raw.isEmpty else { return nil }
        for keyword in ["Ultra", "Pro", "Free"] where raw.localizedCaseInsensitiveContains(keyword) {
            return "Antigravity \(keyword)"
        }
        return raw
    }
}
