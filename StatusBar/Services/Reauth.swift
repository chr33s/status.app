import AppKit

/// Launches a provider's CLI login flow so the user can re-authenticate when a
/// token is expired/invalid.
///
/// CLIs have no real URL scheme, so this writes a tiny `.command` script that
/// runs the login command and opens it with Terminal. (Using a script avoids
/// needing Apple Events automation entitlements.)
enum Reauth {
    static func start(_ provider: Provider) {
        let command = provider.reauthCommand
        let script = """
        #!/bin/zsh
        clear
        echo "Re-authenticating \(provider.fullName)…"
        echo
        \(command)
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reauth-\(provider.rawValue).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            // Fall back to the provider's dashboard if we can't stage the script.
            NSWorkspace.shared.open(provider.dashboardURL)
            return
        }

        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { _, error in
            if error != nil {
                // Older path or missing Terminal — fall back to a generic open.
                NSWorkspace.shared.open(url)
            }
        }
    }
}
