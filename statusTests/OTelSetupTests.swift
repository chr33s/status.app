import Foundation
import Testing
@testable import status

@Suite(.serialized)
struct OTelSetupTests {
    private func withSettings(_ text: String?, _ body: (URL) throws -> Void) throws {
        let suite = "status.telemetry.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.json")
        if let text { try text.write(to: file, atomically: true, encoding: .utf8) }
        let original = OTelSetup.access
        let originalDefaults = OTelSetup.defaults
        OTelSetup.defaults = defaults
        OTelSetup.access = SecurityScopedAccess(defaults: defaults, securityScoped: false)
        defer {
            OTelSetup.access = original
            OTelSetup.defaults = originalDefaults
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
        }
        try OTelSetup.access.authorize(.claudeData, url: folder)
        try body(file)
    }

    @Test(arguments: ["invalid json", "[]", "{\"env\":\"invalid\"}"])
    func malformedSettingsReportFailureAndStayUntouched(_ text: String) throws {
        try withSettings(text) { file throws in
            #expect(throws: CocoaError.self) { try OTelSetup.configure(endpoint: "http://localhost:4318") }
            let afterConfigure = try String(contentsOf: file, encoding: .utf8)
            #expect(afterConfigure == text)
            #expect(throws: CocoaError.self) { try OTelSetup.revert() }
            let afterRevert = try String(contentsOf: file, encoding: .utf8)
            #expect(afterRevert == text)
        }
    }

    @Test func configurePreservesUnrelatedSettingsAndDetectsDisabledTelemetry() throws {
        try withSettings("{\"theme\":\"dark\",\"env\":{\"CUSTOM\":\"keep\"}}") { file in
            let endpoint = "http://localhost:4318"
            try OTelSetup.configure(endpoint: endpoint)
            #expect(OTelSetup.isConfigured(.claude, endpoint: endpoint))
            let json = JSON(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
            #expect(json["theme"].string == "dark")
            #expect(json["env"]["CUSTOM"].string == "keep")
            try OTelSetup.revert()
            #expect(!OTelSetup.isConfigured(.claude, endpoint: endpoint))
            try "{\"env\":{\"OTEL_EXPORTER_OTLP_ENDPOINT\":\"\(endpoint)\",\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"0\"}}"
                .write(to: file, atomically: true, encoding: .utf8)
            #expect(!OTelSetup.isConfigured(.claude, endpoint: endpoint))
        }
    }

    @Test func writeFailuresAreReported() throws {
        try withSettings(nil) { file in
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            #expect(throws: CocoaError.self) { try OTelSetup.configure(endpoint: "http://localhost:4318") }
        }
    }

    @Test func revertRestoresPreviousSettingsAndKeepsLaterUserEdits() throws {
        try withSettings("{\"env\":{\"OTEL_EXPORTER_OTLP_ENDPOINT\":\"https://collector.example\",\"OTEL_METRICS_EXPORTER\":\"console\"}}") { file in
            try OTelSetup.configure(endpoint: "http://localhost:4318")
            try OTelSetup.configure(endpoint: "http://localhost:4318")
            var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var env = try #require(root["env"] as? [String: Any])
            env["OTEL_METRIC_EXPORT_INTERVAL"] = "20000"
            root["env"] = env
            try JSONSerialization.data(withJSONObject: root).write(to: file)
            try OTelSetup.revert()
            let restored = JSON(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
            #expect(restored["env"]["OTEL_EXPORTER_OTLP_ENDPOINT"].string == "https://collector.example")
            #expect(restored["env"]["OTEL_METRICS_EXPORTER"].string == "console")
            #expect(restored["env"]["OTEL_METRIC_EXPORT_INTERVAL"].string == "20000")
            #expect(restored["env"]["CLAUDE_CODE_ENABLE_TELEMETRY"].value == nil)
        }
    }
}
