import AppKit
import Darwin
import ClipatoCore
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

@MainActor
final class CLISkillToolsTests: XCTestCase {
    func testToolsExposeOriginalDefinitionsWithoutAutomationOrLibraryAccess() async throws {
        let root = try directory()
        let library = root.appendingPathComponent("Unused Library")
        let access = AutomationAccess(defaults: try defaults(enabled: false))
        let all = try await execute(["--library", library.path, "tools"], root: root, access: access)
        XCTAssertEqual(all.status, 0, all.errors)
        let definitions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(all.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(definitions as NSArray, MCPTools.definitions as NSArray)
        let single = try await execute(["tools", "image_resize"], root: root, access: access)
        XCTAssertEqual(single.status, 0, single.errors)
        let definition = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(single.output.utf8)) as? [String: Any])
        XCTAssertEqual(definition as NSDictionary,
                       try XCTUnwrap(MCPTools.definitions.first { $0["name"] as? String == "image_resize" }) as NSDictionary)
        for command in [["tools", "--help"], ["call", "--help"], ["help", "tools"], ["help", "call"]] {
            let result = try await execute(command, root: root, access: access)
            XCTAssertEqual(result.status, 0, result.errors)
            XCTAssertTrue(result.output.contains("clipato"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testCallCompressesAndResizesRealImagesWithoutChangingInputs() async throws {
        let root = try directory()
        let source = try image(in: root)
        let original = try Data(contentsOf: source)
        let library = root.appendingPathComponent("Unused Library")
        let access = AutomationAccess(defaults: try defaults())
        let input = try json(["files": [source.path], "output": root.appendingPathComponent("compressed").path,
                              "targetBytes": 2048, "format": "jpeg", "allowResizing": true], in: root)
        let compressed = try await execute(["call", "image_compress", "--input", input.path, "--library", library.path],
                                           root: root, access: access)
        XCTAssertEqual(compressed.status, 0, compressed.errors)
        let compressedPaths = try XCTUnwrap(try object(compressed.output)["files"] as? [String])
        XCTAssertEqual(compressedPaths.count, 1)
        let compressedURL = URL(fileURLWithPath: compressedPaths[0])
        XCTAssertLessThanOrEqual(try Data(contentsOf: compressedURL).count, 2048)
        let compressedSource = try XCTUnwrap(CGImageSourceCreateWithURL(compressedURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(compressedSource) as String?, UTType.jpeg.identifier)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(compressedSource, 0, nil))

        let resizeInput = try json(["files": [source.path], "output": root.appendingPathComponent("resized").path,
                                    "format": "png", "sizes": [["width": 64, "height": 64, "mode": "pad"],
                                                                ["width": 32, "height": 24, "mode": "crop"]]], in: root)
        let resized = try await execute(["--library", library.path, "call", "image_resize", "--input", resizeInput.path],
                                        root: root, access: access)
        XCTAssertEqual(resized.status, 0, resized.errors)
        let resizedPaths = try XCTUnwrap(try object(resized.output)["files"] as? [String])
        XCTAssertEqual(resizedPaths.count, 2)
        for (index, path) in resizedPaths.enumerated() {
            let decoded = try LibraryStore.readImage(at: URL(fileURLWithPath: path))
            XCTAssertEqual(decoded.width, index == 0 ? 64 : 32)
            XCTAssertEqual(decoded.height, index == 0 ? 64 : 24)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testCallReadsJSONFromStandardInputWithoutMCPProtocol() async throws {
        let root = try directory()
        let first = try image(in: root)
        let second = root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: first, to: second)
        let input = try json(["files": [first.path, second.path]], in: root)
        let library = root.appendingPathComponent("Unused Library")
        let result = try await execute(["call", "files_find_duplicates", "--input", "-", "--library", library.path],
                                       root: root, access: AutomationAccess(defaults: try defaults()), input: input)
        XCTAssertEqual(result.status, 0, result.errors)
        let groups = try XCTUnwrap(try object(result.output)["groups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0]["urls"] as? [String], [first.path, second.path])
        XCTAssertNotNil(groups[0]["sha256"] as? String)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(result.output.contains("jsonrpc"))
    }

    func testMalformedUnknownAndMissingArgumentsHaveNoBusinessSideEffects() async throws {
        let root = try directory()
        let source = try image(in: root)
        let library = root.appendingPathComponent("Unused Library")
        let output = root.appendingPathComponent("Output")
        let valid = try json(["files": [source.path], "output": output.path], in: root)
        let unknown = try json(["files": [source.path], "output": output.path, "unexpected": true], in: root)
        let invalidObjects = [Data("{broken".utf8), Data("[]".utf8), Data("null".utf8), Data([0xFF, 0xFE, 0x41])]
        var arguments: [[String]] = [
            ["tools", "missing_tool"], ["tools", "image_convert", "image_resize"],
            ["call"], ["call", "image_convert"], ["call", "missing_tool", "--input", valid.path],
            ["call", "image_convert", "--input", unknown.path],
            ["call", "image_convert", "--input", valid.path, "--unknown"]
        ]
        for data in invalidObjects {
            let file = root.appendingPathComponent("invalid-\(UUID().uuidString).json")
            try data.write(to: file)
            arguments.append(["call", "image_convert", "--input", file.path])
        }
        let access = AutomationAccess(defaults: try defaults())
        for command in arguments {
            let result = try await execute(["--library", library.path] + command, root: root, access: access)
            XCTAssertEqual(result.status, 2, result.errors)
            XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testDisabledPrivacyAndRevokedAuthorizationsRejectCalls() async throws {
        let root = try directory()
        let source = try image(in: root)
        let output = root.appendingPathComponent("Output")
        let library = root.appendingPathComponent("Unused Library")
        let input = try json(["files": [source.path], "output": output.path], in: root)
        let command = ["call", "image_convert", "--input", input.path, "--library", library.path]
        let disabled = try defaults(enabled: false)
        let privateDefaults = try defaults(enabled: true, privacyMode: true)
        let revokedDefaults = try defaults()
        let revoked = AutomationAccess(defaults: revokedDefaults)
        MCPSettings.setEnabled(false, in: revokedDefaults)
        MCPSettings.setEnabled(true, in: revokedDefaults)
        for access in [AutomationAccess(defaults: disabled), AutomationAccess(defaults: privateDefaults), revoked] {
            let result = try await execute(command, root: root, access: access)
            XCTAssertEqual(result.status, 1, result.errors)
            XCTAssertTrue(result.errors.contains(MCPServerError.disabled.localizedDescription))
            XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCallLogsOriginalJSONAndCallerInTheCommandSession() async throws {
        let root = try directory()
        let source = try image(in: root)
        let parameters: [String: Any] = ["files": [source.path], "output": root.appendingPathComponent("尺寸 空格 '输出'").path,
                                        "format": "png", "quality": 87,
                                        "sizes": [["width": 32, "height": 24, "mode": "pad"]]]
        let input = try json(parameters, in: root)
        let settings = try defaults()
        let logFile = root.appendingPathComponent("access.log")
        let log = MCPAccessLog(fileURL: logFile, defaults: settings)
        let command = ["call", "image_resize", "--input", input.path, "--library", root.appendingPathComponent("Unused Library").path]
        let result = try await execute(command, root: root, access: AutomationAccess(defaults: settings), accessLog: log)
        XCTAssertEqual(result.status, 0, result.errors)
        let entries = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").map { try object(String($0)) }
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map { $0["method"] as? String }, ["cli/run", "cli/call", "cli/run"])
        XCTAssertEqual(entries.map { $0["status"] as? String }, ["received", "received", "completed"])
        XCTAssertEqual(entries[1]["tool"] as? String, "image_resize")
        XCTAssertEqual(try XCTUnwrap(entries[1]["params"] as? [String: Any]) as NSDictionary, parameters as NSDictionary)
        XCTAssertEqual(Set(entries.compactMap { $0["sessionID"] as? String }).count, 1)
        XCTAssertTrue(entries.allSatisfy { $0["transport"] as? String == "cli" })
        XCTAssertEqual(try XCTUnwrap(entries[0]["caller"] as? [String: Any]) as NSDictionary,
                       try XCTUnwrap(entries[1]["caller"] as? [String: Any]) as NSDictionary)
        XCTAssertNil(entries[2]["params"])
        XCTAssertEqual(entries[2]["exitCode"] as? Int, 0)
    }

    func testOversizedJSONLogRejectsTheCallBeforeOpeningTheLibrary() async throws {
        let root = try directory()
        let settings = try defaults()
        settings.set(1, forKey: MCPAccessLog.maximumMBKey)
        settings.synchronize()
        let logFile = root.appendingPathComponent("access.log")
        let log = MCPAccessLog(fileURL: logFile, defaults: settings)
        let input = try json(["name": String(repeating: "x", count: 1_100_000)], in: root)
        let library = root.appendingPathComponent("Unused Library")
        let result = try await execute(["call", "collection_create", "--input", input.path, "--library", library.path],
                                       root: root, access: AutomationAccess(defaults: settings), accessLog: log)
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.errors.contains("tool not executed"), result.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        let entries = try String(contentsOf: logFile, encoding: .utf8).split(separator: "\n").map { try object(String($0)) }
        XCTAssertEqual(entries.map { $0["method"] as? String }, ["cli/run", "cli/run"])
        XCTAssertEqual(entries.last?["status"] as? String, "failed")
    }

    func testRevocationCancelsAnActiveJSONCallAndRemovesStagedOutput() async throws {
        let root = try directory()
        let source = try image(in: root)
        let output = root.appendingPathComponent("cancelled.gif")
        let library = root.appendingPathComponent("Unused Library")
        let input = try json(["files": Array(repeating: source.path, count: 4096), "output": output.path,
                              "format": "gif", "fps": 1], in: root)
        let settings = try defaults()
        let access = AutomationAccess(defaults: settings)
        let revoke = Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".clipato-export-") }) {
                    MCPSettings.setEnabled(false, in: settings)
                    return true
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        defer { revoke.cancel() }
        let result = try await execute(["call", "export_images", "--input", input.path, "--library", library.path],
                                       root: root, access: access)
        let revokedWhileProcessing = try await revoke.value
        XCTAssertTrue(revokedWhileProcessing)
        XCTAssertEqual(result.status, 1, result.errors)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.errors.contains(MCPServerError.disabled.localizedDescription), result.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".clipato-export-") })
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func json(_ value: [String: Any], in root: URL) throws -> URL {
        let url = root.appendingPathComponent("input-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: url)
        return url
    }

    private func image(in root: URL) throws -> URL {
        let width = 160
        let height = 120
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var state: UInt32 = 0x12345678
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                state = state &* 1_664_525 &+ 1_013_904_223
                pixels[pixel * 4 + channel] = UInt8(truncatingIfNeeded: state >> 24)
            }
            pixels[pixel * 4 + 3] = 255
        }
        let url = root.appendingPathComponent("原图 空格 'photo'.png")
        try LibraryStore.writePNG(try XCTUnwrap(context.makeImage()), to: url)
        return url
    }

    private func defaults(enabled: Bool = true, privacyMode: Bool = false) throws -> UserDefaults {
        let suite = "Clipato.CLISkillToolsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(enabled, forKey: MCPSettings.enabledKey)
        defaults.set(privacyMode, forKey: "privacyMode")
        defaults.synchronize()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        return defaults
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.CLISkillTools.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func execute(_ arguments: [String], root: URL, access: AutomationAccess, accessLog: MCPAccessLog? = nil,
                         input: URL? = nil) async throws -> (status: Int32, output: String, errors: String) {
        let output = root.appendingPathComponent("stdout-\(UUID().uuidString)")
        let errors = root.appendingPathComponent("stderr-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        let inputHandle = try input.map { try FileHandle(forReadingFrom: $0) }
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedErrors = dup(STDERR_FILENO)
        let savedInput = inputHandle == nil ? nil : dup(STDIN_FILENO)
        XCTAssertGreaterThanOrEqual(savedOutput, 0)
        XCTAssertGreaterThanOrEqual(savedErrors, 0)
        XCTAssertEqual(dup2(outputHandle.fileDescriptor, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(errorHandle.fileDescriptor, STDERR_FILENO), STDERR_FILENO)
        if let inputHandle { XCTAssertEqual(dup2(inputHandle.fileDescriptor, STDIN_FILENO), STDIN_FILENO) }
        let status = await ClipatoCLI.run(arguments: arguments, access: access, accessLog: accessLog)
        fflush(stdout)
        fflush(stderr)
        XCTAssertEqual(dup2(savedOutput, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(savedErrors, STDERR_FILENO), STDERR_FILENO)
        XCTAssertEqual(close(savedOutput), 0)
        XCTAssertEqual(close(savedErrors), 0)
        if let savedInput {
            XCTAssertEqual(dup2(savedInput, STDIN_FILENO), STDIN_FILENO)
            XCTAssertEqual(close(savedInput), 0)
        }
        try outputHandle.close()
        try errorHandle.close()
        try inputHandle?.close()
        return (status, try String(contentsOf: output, encoding: .utf8), try String(contentsOf: errors, encoding: .utf8))
    }
}
