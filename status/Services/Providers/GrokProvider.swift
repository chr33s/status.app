import Foundation
import os

private let log = Logger(subsystem: "app.status", category: "provider.grok")

/// xAI Grok session status via the **Grok CLI** OIDC login
/// (`~/.grok/auth.json`). xAI doesn't publish a per-account quota endpoint, so
/// this provider verifies the access token against the standard OIDC userinfo
/// endpoint and surfaces the token's `tier` claim as the plan label.
///
/// Actual usage data (tokens, requests, cost) is tracked via OpenTelemetry
/// metrics that the Grok CLI emits — see `OTelMetricsParser`.
///
/// ── Verify on a real Mac ──
/// `userinfo_endpoint` comes from `auth.x.ai/.well-known/openid-configuration`.
/// A 401 there drives the store's refresh-and-retry path.
struct GrokProvider: UsageProviding {
    private let userinfoURL = URL(string: "https://auth.x.ai/oauth2/userinfo")!
    
    // Potential usage endpoints to probe (based on common API patterns)
    private let usageEndpoints = [
        "https://api.x.ai/v1/usage",
        "https://api.x.ai/v1/account/usage",
        "https://api.x.ai/v1/me/usage",
        "https://console.x.ai/api/usage",
        "https://console.x.ai/api/v1/usage",
    ]

    func fetch(_ request: ProviderRequest) async throws -> UsageSnapshot {
        guard case let .oauth(token, accountID, displayName) = request.credential else {
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

        // First validate the token via userinfo
        log.debug("validating token via userinfo")
        let userinfoResult: HTTPResult
        do {
            userinfoResult = try await HTTPClient.send(userinfoURL, headers: [
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
        let email = userinfoResult.json["email"].string ?? displayName
        snapshot.planName = (payload["tier"] as? Int).map { "Grok Tier \($0)" }
            ?? displayName
            ?? "Grok CLI"
        
        // Try to fetch usage data from potential endpoints
        if let usageData = await probeUsageEndpoints(token: token, accountID: accountID) {
            log.info("found usage data from endpoint")
            parseUsageData(usageData, into: &snapshot)
        }
        
        // If we still have no usage sections, fall back to the note
        if snapshot.sections.isEmpty {
            let who = email ?? "your xAI account"
            snapshot.note = "Signed in as \(who). xAI doesn't expose per-account quota — open the dashboard for usage details."
        }
        
        return snapshot
    }
    
    /// Probes potential usage endpoints to find one that returns data.
    /// Returns the first successful response, or nil if all fail.
    private func probeUsageEndpoints(token: String, accountID: String?) async -> HTTPResult? {
        for urlString in usageEndpoints {
            guard let url = URL(string: urlString) else { continue }
            
            log.debug("probing usage endpoint: \(urlString, privacy: .public)")
            
            var headers = [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "Content-Type": "application/json",
            ]
            
            // Some APIs might need account/team ID in headers
            if let accountID {
                headers["x-team-id"] = accountID
                headers["x-account-id"] = accountID
            }
            
            do {
                let result = try await HTTPClient.send(url, headers: headers, failOnError: false)
                
                // Check if we got a successful response with data
                if (200..<300).contains(result.status) && result.json.value != nil {
                    log.info("usage endpoint succeeded: \(urlString, privacy: .public)")
                    log.debug("response: \(String(describing: result.json.value), privacy: .public)")
                    return result
                } else {
                    log.debug("endpoint returned status \(result.status): \(urlString, privacy: .public)")
                }
            } catch {
                log.debug("endpoint failed: \(urlString, privacy: .public) - \(error.localizedDescription, privacy: .public)")
            }
        }
        
        log.notice("no usage endpoint returned data")
        return nil
    }
    
    /// Parse usage data from the API response and populate the snapshot.
    /// Looks for common patterns in usage responses (rate limits, quotas, etc.)
    private func parseUsageData(_ result: HTTPResult, into snapshot: inout UsageSnapshot) {
        guard let data = result.json.value as? [String: Any] else {
            log.debug("usage data is not a dictionary")
            return
        }
        
        log.debug("parsing usage data keys: \(data.keys.joined(separator: ", "), privacy: .public)")
        
        // Pattern 1: Rate limit headers (like Claude/Codex)
        if let section = parseRateLimitHeaders(result) {
            snapshot.sections.append(section)
        }
        
        // Pattern 2: Quota objects in response body
        if let sections = parseQuotaObjects(data) {
            snapshot.sections.append(contentsOf: sections)
        }
        
        // Pattern 3: Usage/limit pairs
        if let sections = parseUsageLimitPairs(data) {
            snapshot.sections.append(contentsOf: sections)
        }
    }
    
    private func parseRateLimitHeaders(_ result: HTTPResult) -> UsageSection? {
        // Look for x-ratelimit-* headers (common pattern)
        let prefixes = ["x-ratelimit", "x-xai-ratelimit", "ratelimit"]
        
        for prefix in prefixes {
            guard let limitStr = result.header("\(prefix)-limit"),
                  let remainingStr = result.header("\(prefix)-remaining"),
                  let limit = Double(limitStr),
                  let remaining = Double(remainingStr) else {
                continue
            }
            
            let used = limit - remaining
            let fraction = limit > 0 ? used / limit : 0
            
            var section = UsageSection(
                title: "Rate Limit",
                fraction: fraction,
                leading: Format.percentUsed(fraction),
                trailing: nil
            )
            
            if let reset = result.header("\(prefix)-reset"),
               let date = SessionUsage.resetDate(from: reset) {
                section.trailing = Format.resetCountdown(to: date)
            }
            
            return section
        }
        
        return nil
    }
    
    private func parseQuotaObjects(_ data: [String: Any]) -> [UsageSection]? {
        var sections: [UsageSection] = []
        
        // Look for "quotas", "limits", "usage" keys
        let keys = ["quotas", "limits", "usage", "rate_limits", "rateLimits"]
        
        for key in keys {
            if let quotas = data[key] as? [[String: Any]] {
                for quota in quotas {
                    if let section = sectionFromQuota(quota) {
                        sections.append(section)
                    }
                }
            } else if let quota = data[key] as? [String: Any] {
                // Single quota object
                if let section = sectionFromQuota(quota) {
                    sections.append(section)
                }
            }
        }
        
        return sections.isEmpty ? nil : sections
    }
    
    private func sectionFromQuota(_ quota: [String: Any]) -> UsageSection? {
        let json = JSON(quota)
        
        // Try to extract title
        let title = json["name"].string ?? json["type"].string ?? json["window"].string ?? "Usage"
        
        // Try various patterns for usage/limit
        var fraction: Double?
        
        // Pattern: remaining/total
        if let remaining = json["remaining"].double ?? json["remainingFraction"].double,
           let total = json["total"].double ?? json["limit"].double {
            fraction = total > 0 ? (total - remaining) / total : 0
        }
        // Pattern: used/limit
        else if let used = json["used"].double ?? json["utilization"].double,
                let limit = json["limit"].double ?? json["total"].double {
            fraction = limit > 0 ? used / limit : 0
        }
        // Pattern: just a fraction (0-1)
        else if let util = json["utilization"].double ?? json["fraction"].double {
            fraction = util
        }
        
        guard let frac = fraction else { return nil }
        
        var section = UsageSection(
            title: title,
            fraction: min(max(frac, 0), 1),
            leading: Format.percentUsed(frac),
            trailing: nil
        )
        
        if let reset = json["reset"].string ?? json["resetAt"].string ?? json["reset_at"].string,
           let date = SessionUsage.resetDate(from: reset) {
            section.trailing = Format.resetCountdown(to: date)
        }
        
        return section
    }
    
    private func parseUsageLimitPairs(_ data: [String: Any]) -> [UsageSection]? {
        // Look for top-level usage/limit keys
        let json = JSON(data)
        
        if let used = json["used"].double ?? json["usage"].double,
           let limit = json["limit"].double ?? json["quota"].double {
            let fraction = limit > 0 ? used / limit : 0
            
            var section = UsageSection(
                title: "Usage",
                fraction: fraction,
                leading: Format.percentUsed(fraction),
                trailing: nil
            )
            
            if let reset = json["reset"].string ?? json["reset_at"].string,
               let date = SessionUsage.resetDate(from: reset) {
                section.trailing = Format.resetCountdown(to: date)
            }
            
            return [section]
        }
        
        return nil
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
