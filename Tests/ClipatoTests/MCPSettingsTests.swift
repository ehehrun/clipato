import Foundation
import XCTest
@testable import Clipato

final class MCPSettingsTests: XCTestCase {
    func testTrashPermissionRequiresOptInEnabledServiceAndPrivacyOff() throws {
        let suite = "Clipato.MCPTrashPermissionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MCPSettings.allowsTrash(in: defaults))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertFalse(MCPSettings.allowsTrash(in: defaults))
        defaults.set(true, forKey: MCPSettings.allowTrashKey)
        XCTAssertTrue(MCPSettings.allowsTrash(in: defaults))
        defaults.set(true, forKey: "privacyMode")
        XCTAssertFalse(MCPSettings.allowsTrash(in: defaults))
        defaults.set(false, forKey: "privacyMode")
        defaults.set(false, forKey: MCPSettings.enabledKey)
        XCTAssertFalse(MCPSettings.allowsTrash(in: defaults))
    }

    func testServiceIsOptInAndChoiceSurvivesAnotherDefaultsInstance() throws {
        let name = "Clipato.MCPSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertTrue(MCPSettings.isEnabled(in: try XCTUnwrap(UserDefaults(suiteName: name))))
        defaults.set(false, forKey: MCPSettings.enabledKey)
        XCTAssertFalse(MCPSettings.isEnabled(in: try XCTUnwrap(UserDefaults(suiteName: name))))
    }

    func testPrivacyModeBlocksMCPOnEveryReadEvenIfThePreferenceIsManuallyEnabled() throws {
        let name = "Clipato.MCPPrivacyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))

        defaults.set(true, forKey: "privacyMode")
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        defaults.set(false, forKey: MCPSettings.enabledKey)
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertTrue(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(MCPSettings.isEnabled(in: try XCTUnwrap(UserDefaults(suiteName: name))))
    }

    func testConfigurationPreservesExecutablePathWithoutShellEscaping() throws {
        let executable = URL(fileURLWithPath: "/Applications/Clipato \"QA\".app/Contents/MacOS/Clipato")
        let text = try MCPSettings.configuration(executable: executable)
        let configuration = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let servers = try XCTUnwrap(configuration["mcpServers"] as? [String: Any])
        let server = try XCTUnwrap(servers["clipato"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, executable.path)
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
    }

    func testRunningProcessSeesTheEnableSwitchChangedByAnotherProcess() throws {
        let name = "Clipato.MCPCrossProcessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
        }
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        for enabled in [true, false] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = ["write", name, MCPSettings.enabledKey, "-bool", String(enabled)]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(MCPSettings.isEnabled(in: defaults), enabled,
                           "An already-running MCP process must observe the GUI's updated choice.")
        }
    }

    func testArgumentsRejectUnknownFieldsAndBooleanNumericCoercion() throws {
        XCTAssertThrowsError(try MCPInput(["unexpected": 1], allowed: []))
        let input = try MCPInput(["number": true, "boolean": 1, "fraction": 1.5, "relative": "image.png"],
                                 allowed: ["number", "boolean", "fraction", "relative"])
        XCTAssertThrowsError(try input.int("number", default: 1, range: 1...10))
        XCTAssertThrowsError(try input.double("number", default: 1, range: 0...10))
        XCTAssertThrowsError(try input.bool("boolean"))
        XCTAssertThrowsError(try input.int("fraction", default: 1, range: 1...10))
        XCTAssertThrowsError(try input.path("relative"))
        XCTAssertThrowsError(try input.path("missing"))
    }

    @MainActor
    func testToolCatalogHasUniqueNamesAndClosedObjectSchemas() throws {
        let tools = MCPTools.definitions
        let names = try tools.map { try XCTUnwrap($0["name"] as? String) }
        XCTAssertEqual(Set(names).count, names.count)
        for tool in tools {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(tool))
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let required = try XCTUnwrap(schema["required"] as? [String])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertTrue(Set(required).isSubset(of: Set(properties.keys)))
        }
    }
}
