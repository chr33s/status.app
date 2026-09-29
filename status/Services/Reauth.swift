import AppKit

/// Helps the user re-authenticate a provider's CLI themselves.
///
/// Status never runs the login command: it copies it (exactly, with no
/// trailing newline) and can launch Terminal via `NSWorkspace` for
/// convenience. The user pastes and runs it, then chooses Re-check — a
/// launched Terminal is never taken as proof of sign-in.
enum Reauth {
    @MainActor
    @discardableResult
    static func copyCommand(for provider: Provider, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(provider.reauthCommand, forType: .string)
    }

    @MainActor
    static func copyAndOpenTerminal(
        for provider: Provider,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard copyCommand(for: provider) else {
            onFailure("The login command could not be copied.")
            return
        }

        let workspace = NSWorkspace.shared
        guard let terminalURL = workspace.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) else {
            onFailure("Terminal could not be found. Open your terminal manually and paste the copied command.")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        workspace.openApplication(
            at: terminalURL,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in onFailure(message) }
        }
    }
}
