import Foundation
import os

private let log = Logger(subsystem: "app.statusbar", category: "provider.grok")

/// xAI Grok session status via the **Grok CLI** OIDC login
/// (`~/.grok/auth.json`). xAI doesn't publish a per-account quota endpoint, so
/// this provider verifies the access token against the standard OIDC userinfo
/// endpoint and surfaces the token's `tier` claim as the plan label.
///
/// ── Verify on a real Mac ──
/// `userinfo_endpoint` comes from `auth.x.ai/.well-known/openid-configuration`.
/// A 401 there drives the store's refresh-and-retry path.
struct GrokProvider: UsageProviding {
    private let userinfoURL = URL(string: "https://auth.x.ai/oauth2/userinfo")!

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, _, displayName) = request.credential else {
            log.notice("no OIDC credential (API key only)")
            return .notice(plan: "Grok CLI",
                "Grok is using an API key, which has no quota endpoint. Sign in with `grok login` to track session state.")
        }
        let payload = Self.decodeJWT(token)
        // Catch expired tokens locally so the store refreshes instead of
        // failing the request remotely.
        if let exp = payload["exp"].flatMap(Self.asTimestamp), exp < Date() {
            log.error("access token expired locally")
            throw ProviderError.http(status: 401, body: "token expired")
        }

        log.debug("validating token via userinfo")
        let result: HTTPResult
        do {
            result = try await HTTPClient.send(userinfoURL, headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
            ])
        } catch let error as ProviderError where error.isUnauthorized {
            throw error
        } catch {
            log.error("userinfo failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        var snapshot = UsageSnapshot()
        let email = result.json["email"].string ?? displayName
        snapshot.planName = (payload["tier"] as? Int).map { "Grok Tier \($0)" }
            ?? displayName
            ?? "Grok CLI"
        let who = email ?? "your xAI account"
        snapshot.note = "Signed in as \(who). xAI doesn't expose per-account quota — open the dashboard for usage details."
        return snapshot
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
