import AppKit
import Darwin
import ClipatoCore
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class MCPServerSwitchTests: XCTestCase {
    func testMCPServerRequiresItsOwnOptInAlongWithAutomationAndPrivacyOff() throws {
        let defaults = try settings()
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
        XCTAssertNil(defaults.object(forKey: MCPSettings.serverEnabledKey))
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))

        MCPSettings.setServerEnabled(true, in: defaults)
        XCTAssertTrue(MCPSettings.isServerEnabled(in: defaults))
        defaults.set(true, forKey: "privacyMode")
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        MCPSettings.setServerEnabled(true, in: defaults)
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.serverEnabledKey))
        defaults.set(false, forKey: "privacyMode")
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))

        MCPSettings.setServerEnabled(true, in: defaults)
        MCPSettings.setEnabled(false, in: defaults)
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.serverEnabledKey))
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        MCPSettings.setServerEnabled(true, in: defaults)
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        MCPSettings.setEnabled(true, in: defaults)
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults), "Enabling automation must not also enable MCP")
    }

    func testMCPSwitchRevokesOnlyMCPSessionsAndRapidReenableRequiresANewLease() throws {
        let defaults = try settings(serverEnabled: true)
        let cli = AutomationAccess(defaults: defaults)
        let mcp = AutomationAccess(mcpFrom: cli)
        XCTAssertTrue(cli.isAllowed)
        XCTAssertTrue(mcp.isAllowed)
        let masterGeneration = defaults.string(forKey: MCPSettings.generationKey)

        MCPSettings.setServerEnabled(false, in: defaults)
        MCPSettings.setServerEnabled(true, in: defaults)
        XCTAssertTrue(cli.isAllowed)
        XCTAssertEqual(defaults.string(forKey: MCPSettings.generationKey), masterGeneration)
        XCTAssertFalse(mcp.isAllowed)
        try AutomationAccess.$current.withValue(mcp) {
            XCTAssertThrowsError(try AutomationAccess.check()) {
                XCTAssertEqual($0.localizedDescription, MCPServerError.mcpDisabled.localizedDescription)
            }
        }
        XCTAssertTrue(AutomationAccess(mcpFrom: cli).isAllowed)

        MCPSettings.setEnabled(false, in: defaults)
        MCPSettings.setEnabled(true, in: defaults)
        MCPSettings.setServerEnabled(true, in: defaults)
        XCTAssertFalse(cli.isAllowed)
        XCTAssertFalse(mcp.isAllowed)
        XCTAssertTrue(AutomationAccess(mcpFrom: AutomationAccess(defaults: defaults)).isAllowed)
    }

    func testDerivingMCPScopeCannotRenewARevokedMasterAuthorization() throws {
        let defaults = try settings(serverEnabled: true)
        let original = AutomationAccess(defaults: defaults)
        MCPSettings.setEnabled(false, in: defaults)
        MCPSettings.setEnabled(true, in: defaults)
        MCPSettings.setServerEnabled(true, in: defaults)

        let derived = AutomationAccess(mcpFrom: original)
        XCTAssertFalse(derived.isAllowed)
        try AutomationAccess.$current.withValue(derived) {
            XCTAssertThrowsError(try AutomationAccess.check())
        }
        XCTAssertTrue(AutomationAccess(mcpFrom: AutomationAccess(defaults: defaults)).isAllowed)
    }

    func testSkillImageCallWorksWithMCPDisabledAndDoesNotEnableIt() async throws {
        let root = try directory()
        let defaults = try settings()
        let source = try image(in: root)
        let original = try Data(contentsOf: source)
        let output = root.appendingPathComponent("resized")
        let library = root.appendingPathComponent("Unused Vault")
        let input = try json(["files": [source.path], "output": output.path, "format": "png",
                              "sizes": [["width": 20, "height": 12, "mode": "pad"]]], in: root)
        let result = try await execute(["--library", library.path, "call", "image_resize", "--input", input.path],
                                       root: root, access: AutomationAccess(defaults: defaults))
        XCTAssertEqual(result.status, 0, result.errors)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [String])
        XCTAssertEqual(files.count, 1)
        let resized = try LibraryStore.readImage(at: URL(fileURLWithPath: try XCTUnwrap(files.first)))
        XCTAssertEqual(resized.width, 20)
        XCTAssertEqual(resized.height, 12)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testDisablingMCPDoesNotCancelARealCLIExportAlreadyInProgress() async throws {
        let root = try directory()
        let defaults = try settings(serverEnabled: true)
        let source = try image(in: root)
        let original = try Data(contentsOf: source)
        let output = root.appendingPathComponent("completed.gif")
        let library = root.appendingPathComponent("Unused Vault")
        let frameCount = 1024
        let input = try json(["files": Array(repeating: source.path, count: frameCount), "output": output.path,
                              "format": "gif", "fps": 1], in: root)
        let toggle = Task {
            let started = try await waitUntil { try hasStaging(in: root) }
            if started { MCPSettings.setServerEnabled(false, in: defaults) }
            return started
        }
        defer { toggle.cancel() }
        let result = try await execute(["call", "export_images", "--input", input.path, "--library", library.path],
                                       root: root, access: AutomationAccess(defaults: defaults))
        let switchedDuringExport = try await toggle.value
        XCTAssertTrue(switchedDuringExport)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), frameCount)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(gif, frameCount - 1, nil))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(try hasStaging(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testRealMCPProcessRefusesStartupWhenOnlyTheMasterSwitchIsEnabled() async throws {
        let root = try directory()
        let (binary, defaults) = try processExecutable(in: root)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
        XCTAssertFalse(MCPSettings.isServerEnabled(in: defaults))
        let library = root.appendingPathComponent("Unused Vault")
        let session = try Session(binary: binary, arguments: ["--library", library.path, "mcp"], root: root)
        defer { session.stop() }
        let exited = try await waitUntil { !session.process.isRunning }
        XCTAssertTrue(exited)
        guard !session.process.isRunning else { return }
        XCTAssertEqual(session.process.terminationReason, .exit)
        XCTAssertEqual(session.process.terminationStatus, 1)
        XCTAssertTrue(try session.messages().isEmpty)
        XCTAssertTrue(try session.errors().contains(MCPServerError.mcpDisabled.localizedDescription))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testRealIdleMCPSessionDisconnectsWithOpenInputDespiteImmediateReenable() async throws {
        let root = try directory()
        let (binary, defaults) = try processExecutable(in: root)
        MCPSettings.setServerEnabled(true, in: defaults)
        let library = root.appendingPathComponent("Unused Vault")
        let arguments = ["--library", library.path, "mcp"]
        let session = try Session(binary: binary, arguments: arguments, root: root)
        defer { session.stop() }
        try session.send(Self.initialize(id: 1))
        let ready = try await waitUntil { try session.messages().contains { $0["id"] as? Int == 1 && $0["result"] != nil } }
        let initializationErrors = try session.errors()
        XCTAssertTrue(ready, initializationErrors)
        guard ready else { return }

        MCPSettings.setServerEnabled(false, in: defaults)
        MCPSettings.setServerEnabled(true, in: defaults)
        let exited = try await waitUntil { !session.process.isRunning }
        XCTAssertTrue(exited, "Revocation must wake the server while stdin remains open")
        guard !session.process.isRunning else { return }
        XCTAssertEqual(session.process.terminationReason, .exit)
        XCTAssertEqual(session.process.terminationStatus, 1)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
        XCTAssertTrue(MCPSettings.isServerEnabled(in: defaults))
        XCTAssertTrue(try session.errors().contains(MCPServerError.mcpDisabled.localizedDescription))

        let renewed = try Session(binary: binary, arguments: arguments, root: root)
        defer { renewed.stop() }
        try renewed.send(Self.initialize(id: 2))
        let renewedReady = try await waitUntil { try renewed.messages().contains { $0["id"] as? Int == 2 && $0["result"] != nil } }
        let renewalErrors = try renewed.errors()
        XCTAssertTrue(renewedReady, renewalErrors)
        try renewed.input.fileHandleForWriting.close()
        let renewedExited = try await waitUntil { !renewed.process.isRunning }
        XCTAssertTrue(renewedExited)
        if !renewed.process.isRunning { XCTAssertEqual(renewed.process.terminationStatus, 0) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testDisablingMCPDuringRealProtocolExportCancelsWorkAndRemovesStaging() async throws {
        let root = try directory()
        let (binary, defaults) = try processExecutable(in: root)
        MCPSettings.setServerEnabled(true, in: defaults)
        let source = try image(in: root)
        let original = try Data(contentsOf: source)
        let library = root.appendingPathComponent("Unused Vault")
        let output = root.appendingPathComponent("cancelled.gif")
        let session = try Session(binary: binary, arguments: ["mcp", "--library", library.path], root: root)
        defer { session.stop() }
        try session.send(Self.initialize(id: 1))
        let ready = try await waitUntil { try session.messages().contains { $0["id"] as? Int == 1 && $0["result"] != nil } }
        let initializationErrors = try session.errors()
        XCTAssertTrue(ready, initializationErrors)
        guard ready else { return }
        try session.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try session.send(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "export_images", "arguments": ["files": Array(repeating: source.path, count: 4096),
                                                     "output": output.path, "format": "gif", "fps": 1]
        ]])
        let exporting = try await waitUntil { try hasStaging(in: root) }
        let exportErrors = try session.errors()
        XCTAssertTrue(exporting, exportErrors)
        guard exporting else { return }

        MCPSettings.setServerEnabled(false, in: defaults)
        let exited = try await waitUntil { !session.process.isRunning }
        XCTAssertTrue(exited)
        guard !session.process.isRunning else { return }
        XCTAssertEqual(session.process.terminationReason, .exit)
        XCTAssertEqual(session.process.terminationStatus, 1)
        XCTAssertFalse(try session.messages().contains { $0["id"] as? Int == 2 }, "Cancelled work must not deliver a success or error result")
        XCTAssertTrue(try session.errors().contains(MCPServerError.mcpDisabled.localizedDescription))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(try hasStaging(in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
    }

    private func settings(serverEnabled: Bool? = nil) throws -> UserDefaults {
        let name = "Clipato.MCPServerSwitchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        MCPSettings.setEnabled(true, in: defaults)
        if let serverEnabled { MCPSettings.setServerEnabled(serverEnabled, in: defaults) }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
        }
        return defaults
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.MCPServerSwitch.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func processExecutable(in root: URL) throws -> (URL, UserDefaults) {
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let name = "Clipato.MCPServerSwitchProcess.\(UUID().uuidString)"
        let contents = root.appendingPathComponent("CLI.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Clipato")
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: build.appendingPathComponent("Clipato"), to: executable)
        try FileManager.default.copyItem(at: build.appendingPathComponent("Clipato_Clipato.bundle"),
                                        to: resources.appendingPathComponent("Clipato_Clipato.bundle"))
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": name, "CFBundleExecutable": "Clipato", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(LanguageSettings.shared.resolvedLanguage.rawValue, forKey: "language")
        MCPSettings.setEnabled(true, in: defaults)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            defaults.synchronize()
        }
        return (executable, defaults)
    }

    private func image(in root: URL) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                            bytesPerRow: 32 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let url = root.appendingPathComponent("原图 空格 'source'.png")
        try LibraryStore.writePNG(try XCTUnwrap(context.makeImage()), to: url)
        return url
    }

    private func json(_ value: [String: Any], in root: URL) throws -> URL {
        let url = root.appendingPathComponent("input.json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: url)
        return url
    }

    private func hasStaging(in root: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".clipato-export-") }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return try condition()
    }

    private static func initialize(id: Int) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:],
            "clientInfo": ["name": "MCPServerSwitchTests", "version": "1"]
        ]]
    }

    private func execute(_ arguments: [String], root: URL, access: AutomationAccess) async throws
        -> (status: Int32, output: String, errors: String) {
        let output = root.appendingPathComponent("stdout")
        let errors = root.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedErrors = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(savedOutput, 0)
        XCTAssertGreaterThanOrEqual(savedErrors, 0)
        XCTAssertEqual(dup2(outputHandle.fileDescriptor, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(errorHandle.fileDescriptor, STDERR_FILENO), STDERR_FILENO)
        let status = await ClipatoCLI.run(arguments: arguments, access: access)
        fflush(stdout)
        fflush(stderr)
        XCTAssertEqual(dup2(savedOutput, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(savedErrors, STDERR_FILENO), STDERR_FILENO)
        XCTAssertEqual(close(savedOutput), 0)
        XCTAssertEqual(close(savedErrors), 0)
        try outputHandle.close()
        try errorHandle.close()
        return (status, try String(contentsOf: output, encoding: .utf8), try String(contentsOf: errors, encoding: .utf8))
    }

    private final class Session {
        let process = Process()
        let input = Pipe()
        private let output: URL
        private let error: URL

        init(binary: URL, arguments: [String], root: URL) throws {
            output = root.appendingPathComponent("mcp-output-\(UUID().uuidString)")
            error = root.appendingPathComponent("mcp-errors-\(UUID().uuidString)")
            XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
            XCTAssertTrue(FileManager.default.createFile(atPath: error.path, contents: nil))
            let outputHandle = try FileHandle(forWritingTo: output)
            let errorHandle = try FileHandle(forWritingTo: error)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }
            process.executableURL = binary
            process.arguments = arguments
            process.standardInput = input
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
        }

        func send(_ message: [String: Any]) throws {
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
        }

        func messages() throws -> [[String: Any]] {
            let data = try Data(contentsOf: output)
            guard let end = data.lastIndex(of: 10) else { return [] }
            return try data[...end].split(separator: 10).map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
            }
        }

        func errors() throws -> String { try String(contentsOf: error, encoding: .utf8) }

        func stop() {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
    }
}
