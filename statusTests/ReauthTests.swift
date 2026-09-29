import AppKit
import Security
import Testing
@testable import status

@MainActor
struct ReauthTests {
    @Test(arguments: Provider.allCases)
    func copiesExactCommandWithoutNewline(provider: Provider) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(Reauth.copyCommand(for: provider, to: pasteboard))
        let copied = pasteboard.string(forType: .string)
        #expect(copied == provider.reauthCommand)
        #expect(copied?.hasSuffix("\n") == false)
    }

    /// The Terminal Apple Events path is gone: no usage string, and the signed
    /// host app carries none of the temporary exceptions it needed.
    @Test func noAppleEventsOrTemporaryExceptions() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") == nil)
        guard let task = SecTaskCreateFromSelf(nil) else { return }
        for entitlement in [
            "com.apple.security.temporary-exception.apple-events",
            "com.apple.security.temporary-exception.files.home-relative-path.read-only",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write",
        ] {
            #expect(SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) == nil, "\(entitlement)")
        }
    }
}

struct LoadStateAccessTests {
    @Test func authorizationRequiredIsNotSignedOut() {
        let state = LoadState.authorizationRequired(.codexData, lost: false)
        #expect(!state.isConfigured)
        #expect(state.needsAttention)
        #expect(state.snapshot == nil)
        if case .notConfigured = state { Issue.record("access-required must not read as signed out") }
    }
}
