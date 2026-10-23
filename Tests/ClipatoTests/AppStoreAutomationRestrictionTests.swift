import Foundation
import XCTest
@testable import Clipato

#if APP_STORE
final class AppStoreAutomationRestrictionTests: XCTestCase {
    func testStoreExecutableRejectsExternalArgumentsBeforeRunningAnyCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-AppStoreCommandRestriction-\(UUID())")
        let contents = root.appendingPathComponent("CLI.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Clipato")
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: build.appendingPathComponent("Clipato"), to: executable)
        try FileManager.default.copyItem(at: build.appendingPathComponent("Clipato_Clipato.bundle"),
                                        to: resources.appendingPathComponent("Clipato_Clipato.bundle"))
        let name = "Clipato.AppStoreCommandRestrictionTests.\(UUID())"
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": name, "CFBundleExecutable": "Clipato", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        defaults.set(true, forKey: MCPSettings.serverEnabledKey)
        defaults.set(false, forKey: "privacyMode")
        defaults.synchronize()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
        }

        for arguments in [["mcp"], ["--version"], ["call", "image_resize", "--input", "-"]] {
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            let finished = expectation(description: arguments.joined(separator: " "))
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["CFFIXED_USER_HOME"] = root.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { _ in finished.fulfill() }
            try process.run()
            wait(for: [finished], timeout: 5)
            if process.isRunning { process.terminate() }
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 69)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTAssertTrue(message.contains("Mac App Store"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Logs/Clipato").path))
    }

    func testSavedAutomationPermissionsCannotAuthorizeTheStoreEditionOrBeChangedByIt() throws {
        let name = "Clipato.AppStoreAutomationRestrictionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MCPSettings.enabledKey)
        defaults.set(true, forKey: MCPSettings.serverEnabledKey)
        defaults.set(true, forKey: MCPSettings.allowTrashKey)
        defaults.set("master-before-store", forKey: MCPSettings.generationKey)
        defaults.set("mcp-before-store", forKey: MCPSettings.serverGenerationKey)
        let saved = try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary

        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        XCTAssertFalse(MCPSettings.allowsTrash(in: defaults))
        XCTAssertFalse(AutomationAccess(defaults: defaults).isAllowed)
        for enabled in [false, true] {
            MCPSettings.setEnabled(enabled, in: defaults)
            MCPSettings.setServerEnabled(enabled, in: defaults)
        }

        XCTAssertEqual(try XCTUnwrap(defaults.persistentDomain(forName: name)) as NSDictionary, saved)
    }

    func testSkillInstallationAndExportFailBeforeCreatingOrReplacingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-AppStoreSkillRestriction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("not-an-executable")
        let destination = root.appendingPathComponent("not-created/clipato")

        XCTAssertThrowsError(try SkillInstallation.install(to: destination, executable: executable)) { error in
            XCTAssertEqual((error as NSError).domain, "Clipato.SkillInstallation")
            XCTAssertEqual((error as NSError).code, 4)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))

        let existing = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("keep.txt")
        try Data("installed by user".utf8).write(to: sentinel)
        XCTAssertThrowsError(try SkillInstallation.install(to: existing, executable: executable, replaceExisting: true)) { error in
            XCTAssertEqual((error as NSError).domain, "Clipato.SkillInstallation")
            XCTAssertEqual((error as NSError).code, 4)
        }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "installed by user")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.path), ["keep.txt"])
    }
}
#endif
