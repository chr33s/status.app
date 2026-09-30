import Foundation

/// One provider's usage as shared with the widget: the last snapshot plus
/// whether the provider needs attention (expired login, failed fetch).
struct SharedProviderUsage: Codable, Sendable, Identifiable {
    var provider: Provider
    var snapshot: UsageSnapshot?
    var needsAttention: Bool

    var id: String { provider.id }
}

/// Everything the widget renders, written by the app after each refresh.
/// Only configured providers are included, in menu order.
struct SharedUsagePayload: Codable, Sendable {
    var updatedAt: Date
    var providers: [SharedProviderUsage]
}

/// App ⇄ widget hand-off through the shared App Group container.
///
/// The widget runs in its own sandbox: it can't read the CLI credential
/// stores, and it has no way to present the Keychain consent dialog. So the
/// app publishes whatever it last fetched and the widget only reads this file.
enum SharedUsage {
    /// Team-prefixed so macOS grants the group without provisioning changes.
    /// Must match the `com.apple.security.application-groups` entitlement on
    /// both targets ($(TeamIdentifierPrefix)dev.chr33s.status).
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "StatusAppGroupIdentifier") as? String
            ?? "72KB9YQR7B.dev.chr33s.status"
    }

    /// WidgetKit kind for the quota-rings widget; used for targeted reloads.
    static let widgetKind = "QuotaRings"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("usage.json")
    }

    static func write(_ payload: SharedUsagePayload) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func read() -> SharedUsagePayload? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedUsagePayload.self, from: data)
    }
}
