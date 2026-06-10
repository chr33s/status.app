import Foundation

/// Gemini usage via the **Gemini CLI** Google login (OAuth) — no API key.
///
/// Mirrors how the Gemini CLI's `/stats model` quota is sourced: it calls the
/// Code Assist internal endpoint `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
/// with the user's OAuth token and reads per-model quota buckets
/// (`remainingFraction` / reset time).
///
/// ── Verify on a real Mac ──
/// This is a `v1internal` (undocumented) endpoint; the request body and bucket
/// field names are parsed defensively and isolated here. When a bucket is full
/// the API may omit `remainingAmount`/`remainingFraction`, which we treat as 0% used.
struct GeminiProvider: UsageProviding {
    private let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _) = request.credential else {
            return .notice(plan: "Gemini CLI", "Gemini is using an API key, which has no quota endpoint. Sign in with Google (`gemini`) to see limits.")
        }

        let body = try JSONSerialization.data(withJSONObject: [
            "metadata": ["pluginType": "GEMINI", "platform": "DARWIN"],
        ])
        let result = try await HTTPClient.send(
            endpoint, method: "POST",
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
            body: body
        )

        var snapshot = UsageSnapshot()
        snapshot.planName = "Gemini CLI"
        for bucket in Self.quotaBuckets(in: result.json.value) {
            if let section = section(from: bucket) {
                snapshot.sections.append(section)
            }
        }
        if snapshot.sections.isEmpty {
            snapshot.note = "Signed in via Gemini CLI. No per-model quota was returned for this account."
        }
        return snapshot
    }

    private func section(from bucket: JSON) -> UsageSection? {
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
            section.trailing = Format.resetCountdown(to: date)
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
