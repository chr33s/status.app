import AppKit

/// Launches a provider's CLI login flow so the user can re-authenticate when a
/// token is expired/invalid.
///
/// CLIs have no real URL scheme, so this tells Terminal to run the login
/// command via Apple Events. A staged `.command` script can't be used now that
/// the app is sandboxed: the sandbox quarantines every file the app writes,
/// and Gatekeeper refuses to run quarantined unsigned scripts ("damaged").
/// Automating Terminal instead requires the `temporary-exception.apple-events`
/// entitlement plus `NSAppleEventsUsageDescription`, and macOS asks the user
/// for consent on first use.
enum Reauth {
    static func start(_ provider: Provider) {
        let command = "clear; echo 'Re-authenticating \(provider.fullName)…'; echo; \(provider.reauthCommand)"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        if NSAppleScript(source: source)?.executeAndReturnError(&error) == nil {
            // Automation denied or Terminal unavailable — fall back to the
            // provider's dashboard in the browser.
            _ = NSWorkspace.shared.open(provider.dashboardURL)
        }
    }
}
