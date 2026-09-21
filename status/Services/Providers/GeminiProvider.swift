import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.gemini")

/// Gemini usage via the **Gemini CLI** Google login (OAuth) — no API key.
///
/// Mirrors how the Gemini CLI's `/stats model` quota is sourced: two calls
/// against the Code Assist internal API:
///  1. `loadCodeAssist` to resolve the user's `cloudaicompanionProject`
///  2. `retrieveUserQuota` with that project ID, returning per-model quota
///     buckets (`remainingFraction` / reset time).
///
/// ── Verify on a real Mac ──
/// These are `v1internal` (undocumented) endpoints; request shapes are pulled
/// from the gemini-cli sources and isolated here. Free-tier accounts may not
/// have a `cloudaicompanionProject` — we honor `GOOGLE_CLOUD_PROJECT` as a
/// fallback, otherwise show a friendly "signed in" note. When a bucket is full
/// the API may omit `remainingAmount`/`remainingFraction`, which we treat as 0% used.
struct GeminiProvider: UsageProviding {
    /// Performs a POST and returns the result, throwing `ProviderError.http` on
    /// non-2xx. Injectable for tests.
    typealias Transport = @Sendable (URL, [String: String], Data) async throws -> HTTPResult

    private static let base = URL(string: "https://cloudcode-pa.googleapis.com")!
    static let loadURL = base.appendingPathComponent("v1internal:loadCodeAssist")
    static let quotaURL = base.appendingPathComponent("v1internal:retrieveUserQuota")

    private let transport: Transport
    private let environment: [String: String]
    private let now: @Sendable () -> Date

    init(
        transport: @escaping Transport = { url, headers, body in
            try await HTTPClient.send(url, method: "POST", headers: headers, body: body)
        },
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.environment = environment
        self.now = now
    }

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _, displayName) = request.credential else {
            log.notice("no OAuth credential (API key only)")
            return .notice(plan: "Gemini CLI", "Gemini is using an API key, which has no quota endpoint. Sign in with Google (`gemini`) to see limits.")
        }

        var snapshot = UsageSnapshot()
        snapshot.planName = displayName ?? "Gemini CLI"

        guard let project = try await resolveProject(token: token) else {
            log.notice("no cloudaicompanionProject and no GOOGLE_CLOUD_PROJECT env var")
            snapshot.note = "Signed in via Gemini CLI. No Cloud project is linked to this account, so per-model quota isn't available."
            return snapshot
        }

        log.debug("retrieveUserQuota project=\(project, privacy: .public)")
        let quotaBody = try JSONSerialization.data(withJSONObject: ["project": project])
        let result: HTTPResult
        do {
            result = try await transport(Self.quotaURL, authHeaders(token), quotaBody)
        } catch {
            log.error("retrieveUserQuota failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        let now = now()
        snapshot.sections = Self.quotaBuckets(in: result.json.value).map { Self.section(from: $0, now: now) }
        log.info("loaded \(snapshot.sections.count) quota bucket(s)")
        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in via Gemini CLI. No per-model quota was returned for this account."
        }
        return snapshot
    }

    /// Calls `loadCodeAssist` to discover the Cloud project linked to the user,
    /// falling back to `GOOGLE_CLOUD_PROJECT` (matching the CLI's behavior).
    ///
    /// `metadata.platform` / `metadata.ideType` are server-side enums; the
    /// gemini-cli sends the `*_UNSPECIFIED` values, so we do the same to avoid
    /// `INVALID_ARGUMENT` on enum mismatches.
    private func resolveProject(token: String) async throws -> String? {
        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ])
        log.debug("loadCodeAssist")
        let result: HTTPResult
        do {
            result = try await transport(Self.loadURL, authHeaders(token), body)
        } catch {
            log.error("loadCodeAssist failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        if let project = result.json["cloudaicompanionProject"].string, !project.isEmpty {
            log.debug("resolved project from loadCodeAssist")
            return project
        }
        for key in ["GOOGLE_CLOUD_PROJECT", "GEMINI_PROJECT"] {
            if let value = environment[key], !value.isEmpty {
                log.debug("resolved project from env \(key, privacy: .public)")
                return value
            }
        }
        return nil
    }

    private func authHeaders(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
    }

    static func section(from bucket: JSON, now: Date = Date()) -> UsageSection {
        let model = bucket["modelId"].string ?? bucket["model"].string ?? "Quota"
        // remainingFraction is the fraction *left*; when omitted, the bucket is full.
        let remaining = bucket["remainingFraction"].double ?? bucket["remaining_fraction"].double ?? 1
        let used = min(max(1 - remaining, 0), 1)
        var section = UsageSection(
            title: model,
            fraction: used,
            leading: Format.percentUsed(used),
            trailing: nil
        )
        if let reset = bucket["resetTime"].string ?? bucket["quotaResetTime"].string,
           let date = SessionUsage.resetDate(from: reset) {
            section.trailing = Format.resetCountdown(to: date, now: now)
        }
        return section
    }

    /// Depth-first collection of quota-bucket objects (those carrying a
    /// `remainingFraction` / `remainingAmount` / `modelId` shape).
    static func quotaBuckets(in any: Any?) -> [JSON] {
        var result: [JSON] = []
        func walk(_ value: Any?) {
            if let dict = value as? [String: Any] {
                if dict["remainingFraction"] != nil || dict["remaining_fraction"] != nil
                    || (dict["modelId"] != nil && dict["remainingAmount"] != nil) {
                    result.append(JSON(dict))
                    return // a matched bucket isn't itself a container of more buckets
                }
                for nested in dict.values { walk(nested) }
            } else if let array = value as? [Any] {
                for nested in array { walk(nested) }
            }
        }
        walk(any)
        return result
    }
}
