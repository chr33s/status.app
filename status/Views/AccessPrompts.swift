import AppKit
import SwiftUI

/// Asks the user to pick a CLI folder in an open panel. The selection is the
/// only source of authorization; `SecurityScopedAccess` validates and
/// remembers it.
enum FolderAuthorization {
    enum Outcome {
        case authorized
        case cancelled
        case failed(String)
    }

    @MainActor
    static func choose(_ resource: ExternalResource) -> Outcome {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // CLI folders are dot-folders, hidden by default.
        panel.showsHiddenFiles = true
        panel.title = "\(resource.owner) Access"
        panel.message = resource.accessExplanation
        panel.prompt = "Allow Access"
        let fileManager = FileManager.default
        panel.directoryURL = fileManager.fileExists(atPath: resource.defaultLocation.path)
            ? resource.defaultLocation
            : resource.defaultLocation.deletingLastPathComponent()

        // A menu-bar app isn't active by default; bring the panel forward.
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try SecurityScopedAccess.shared.authorize(resource, url: url)
            return .authorized
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// "Access required" prompt shown when a provider's CLI folder hasn't been
/// granted (or the grant stopped working).
struct FolderAccessPrompt: View {
    let resource: ExternalResource
    let lost: Bool
    var compact = false
    @Environment(UsageStore.self) private var store
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                Text(lost ? "\(resource.owner) access needs to be granted again" : "\(resource.owner) access required")
                    .font(.headline)
            }
            Text(lost
                 ? "Status can no longer open your \(resource.folderName) folder — it may have moved, or access was removed. Choose it again to continue."
                 : resource.accessExplanation)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Expected location: \(resource.expectedPath)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                choose()
            } label: {
                Label("Choose \(resource.folderName) Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(resource.provider.accentColor)
            .controlSize(compact ? .small : .regular)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func choose() {
        switch FolderAuthorization.choose(resource) {
        case .authorized:
            error = nil
            store.reload(resource.provider)
        case .cancelled:
            break
        case .failed(let message):
            error = message
        }
    }
}

/// Shows the provider's login command for the user to run themselves, with
/// Copy / Copy & Open Terminal, and Re-check to look for the new login.
struct ReauthCommandPrompt: View {
    let provider: Provider
    var compact = false
    @Environment(UsageStore.self) private var store
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in again using your CLI:")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
            Text(provider.reauthCommand)
                .font(.system(compact ? .caption : .callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            HStack(spacing: 8) {
                Button {
                    feedback = nil
                    Reauth.copyAndOpenTerminal(for: provider) { message in
                        feedback = message
                        failed = true
                    }
                } label: {
                    Label("Copy & Open Terminal", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.accentColor)
                Button("Copy") {
                    failed = !Reauth.copyCommand(for: provider)
                    feedback = failed ? "The login command could not be copied." : "Copied."
                }
            }
            .controlSize(compact ? .small : .regular)
            Text(feedback ?? "Run the command in your terminal, complete sign-in, then return to Status and choose Re-check.")
                .font(.caption)
                .foregroundStyle(failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                feedback = nil
                failed = false
                store.reload(provider)
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .controlSize(compact ? .small : .regular)
        }
    }
}
