import AppKit
import CoreText
import Darwin
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

@MainActor
final class CLITests: XCTestCase {
    func testCLIRecordsSystemCallerOriginalArgumentsAndDeniedAttempts() async throws {
        let directory = try temporaryDirectory()
        let defaults = try accessDefaults()
        let file = directory.appendingPathComponent("access.log")
        let log = MCPAccessLog(fileURL: file, defaults: defaults)
        let library = directory.appendingPathComponent("中文 空格 '保管箱'")
        let arguments = ["--library", library.path, "vault", "path"]
        let completed = try await execute(arguments, in: directory,
                                          access: AutomationAccess(defaults: defaults), accessLog: log)
        XCTAssertEqual(completed.status, 0, completed.errors)
        MCPSettings.setEnabled(false, in: defaults)
        let denied = try await execute(["--library", library.path, "collection", "create", "Private"], in: directory,
                                       access: AutomationAccess(defaults: defaults), accessLog: log)
        XCTAssertEqual(denied.status, 1)
        let entries = try String(contentsOf: file).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(entries.map { $0["status"] as? String }, ["received", "completed", "received", "denied"])
        XCTAssertEqual((entries[0]["params"] as? [String: [String]])?["arguments"], arguments)
        XCTAssertTrue(entries.allSatisfy { $0["transport"] as? String == "cli" && $0["client"] == nil })
        let caller = try XCTUnwrap(entries[0]["caller"] as? [String: Any])
        XCTAssertEqual((caller["process"] as? [String: Any])?["pid"] as? Int32, getpid())
        XCTAssertFalse(try XCTUnwrap(caller["ancestors"] as? [[String: Any]]).isEmpty)
        XCTAssertEqual(entries[1]["exitCode"] as? Int, 0)
        XCTAssertEqual(entries[3]["exitCode"] as? Int, 1)
        XCTAssertNotNil(entries[1]["durationMs"] as? Int)
        XCTAssertEqual(entries[0]["sessionID"] as? String, entries[1]["sessionID"] as? String)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        let occupied = directory.appendingPathComponent("occupied")
        try Data("keep".utf8).write(to: occupied)
        let brokenLog = MCPAccessLog(fileURL: occupied.appendingPathComponent("access.log"), defaults: defaults)
        MCPSettings.setEnabled(true, in: defaults)
        let failed = try await execute(["--library", library.path, "collection", "create", "Private"], in: directory,
                                       access: AutomationAccess(defaults: defaults), accessLog: brokenLog)
        XCTAssertEqual(failed.status, 1)
        XCTAssertTrue(failed.errors.contains("command not executed"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertEqual(try String(contentsOf: occupied), "keep")
    }

    func testDisablingAutomationDisconnectsAnIdleMCPProcessWithOpenInput() async throws {
        let directory = try temporaryDirectory()
        let binary = try isolatedProcessExecutable(in: directory)
        let bundle = try XCTUnwrap(Bundle(url: directory.appendingPathComponent("CLI.app")))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: try XCTUnwrap(bundle.bundleIdentifier)))
        MCPSettings.setServerEnabled(true, in: defaults)
        let output = directory.appendingPathComponent("mcp-output")
        let errors = directory.appendingPathComponent("mcp-errors")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
        let outputHandle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        let input = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["mcp", "--library", directory.appendingPathComponent("UnusedVault").path]
        process.standardInput = input
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        try process.run()
        try outputHandle.close()
        try errorHandle.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let initialize: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "RevocationTest", "version": "1"]
        ]]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: initialize) + Data([10]))
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        var ready = false
        while process.isRunning && ContinuousClock.now < readyDeadline {
            let lines = try Data(contentsOf: output).split(separator: 10)
            ready = lines.contains {
                guard let message = try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] else { return false }
                return message["id"] as? Int == 1 && message["result"] != nil
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initializationErrors = try String(contentsOf: errors)
        XCTAssertTrue(ready, initializationErrors)
        guard ready else { return }
        MCPSettings.setEnabled(false, in: defaults)
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while process.isRunning && ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.isRunning, "Revocation must disconnect even while the client keeps stdin open")
        if !process.isRunning {
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("UnusedVault").path))
    }

    func testDisabledAndPrivacyModeBlockAllBusinessCommandsBeforeSideEffects() async throws {
        let directory = try temporaryDirectory()
        let library = directory.appendingPathComponent("UnusedVault")
        let image = directory.appendingPathComponent("missing.png")
        let output = directory.appendingPathComponent("output.png")
        let session = directory.appendingPathComponent("Session")
        let exported = directory.appendingPathComponent("Exports")
        let id = UUID().uuidString
        let commands: [[String]] = [
            ["mcp"], ["displays"],
            ["screenshot", "--output", output.path],
            ["collage", "--output", output.path, image.path],
            ["stitch", "--output", output.path, image.path],
            ["export", session.path, "--output", directory.appendingPathComponent("output.gif").path],
            ["export", session.path, "--vault"],
            ["export-images", image.path, "--output", exported.path],
            ["record", "--output", session.path],
            ["vault", "path"], ["vault", "list"], ["vault", "import", image.path],
            ["collection", "list"], ["collection", "create", "Private"],
            ["collection", "rename", id, "Private"], ["collection", "move", id],
            ["collection", "delete", id], ["collection", "items", id],
            ["collection", "add", id, "image:\(id)"], ["collection", "remove", id, "image:\(id)"]
        ]
        for privacyMode in [false, true] {
            let defaults = try accessDefaults(enabled: privacyMode, privacyMode: privacyMode)
            let access = AutomationAccess(defaults: defaults)
            for command in commands {
                let result = try await execute(["--library", library.path] + command, in: directory, access: access)
                XCTAssertEqual(result.status, 1, command.joined(separator: " "))
                XCTAssertTrue(result.output.isEmpty)
                XCTAssertTrue(result.errors.contains(MCPServerError.disabled.localizedDescription), result.errors)
            }
        }
        for path in [library, output, session, exported, directory.appendingPathComponent("output.gif")] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), path.path)
        }
    }

    func testHelpVersionAndPermissionsRemainAvailableWhenAutomationIsDisabled() async throws {
        let directory = try temporaryDirectory()
        let library = directory.appendingPathComponent("UnusedVault")
        let access = AutomationAccess(defaults: try accessDefaults(enabled: false))
        for arguments in [
            ["help"], ["--help"], ["version"], ["--version"], ["permissions"],
            ["mcp", "--help"], ["displays", "--help"], ["screenshot", "--help"],
            ["record", "--help"], ["collage", "--help"], ["stitch", "--help"],
            ["export", "--help"], ["export-images", "--help"],
            ["vault", "list", "--help"], ["collection", "add", "--help"]
        ] {
            let result = try await execute(["--library", library.path] + arguments, in: directory, access: access)
            XCTAssertEqual(result.status, 0, result.errors)
            XCTAssertFalse(result.output.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testReenablingAutomationDoesNotReviveAnOldCLIAuthorization() async throws {
        let directory = try temporaryDirectory()
        let library = directory.appendingPathComponent("UnusedVault")
        let defaults = try accessDefaults()
        let revoked = AutomationAccess(defaults: defaults)
        MCPSettings.setEnabled(false, in: defaults)
        MCPSettings.setEnabled(true, in: defaults)
        let arguments = ["--library", library.path, "vault", "path"]
        let denied = try await execute(arguments, in: directory, access: revoked)
        XCTAssertEqual(denied.status, 1)
        XCTAssertTrue(denied.output.isEmpty)
        XCTAssertTrue(denied.errors.contains(MCPServerError.disabled.localizedDescription))

        let renewed = try await execute(arguments, in: directory, access: AutomationAccess(defaults: defaults))
        XCTAssertEqual(renewed.status, 0, renewed.errors)
        XCTAssertEqual(renewed.output, library.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testCancelledCLITaskDoesNotCreateOutputOrLibrary() async throws {
        let directory = try temporaryDirectory()
        let library = directory.appendingPathComponent("UnusedVault")
        let access = AutomationAccess(defaults: try accessDefaults())
        let task = Task { @MainActor in
            try await execute(["--library", library.path, "collection", "create", "Cancelled"], in: directory, access: access)
        }
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, 130)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testRevokingAutomationCancelsAnExportAlreadyInProgress() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let library = directory.appendingPathComponent("UnusedVault")
        let output = directory.appendingPathComponent("cancelled.gif")
        let defaults = try accessDefaults()
        let access = AutomationAccess(defaults: defaults)
        let revoke = Task.detached {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".clipato-export-") }) {
                    MCPSettings.setEnabled(false, in: defaults)
                    return true
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            return false
        }
        defer { revoke.cancel() }
        let arguments = ["--library", library.path, "export-images"] + Array(repeating: source.path, count: 4_096)
            + ["--format", "gif", "--fps", "1", "--output", output.path]
        let result = try await execute(arguments, in: directory, access: access)
        let revokedDuringExport = try await revoke.value
        XCTAssertTrue(revokedDuringExport)
        XCTAssertEqual(result.status, 1, result.errors)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.errors.contains(MCPServerError.disabled.localizedDescription), result.errors)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".clipato-export-") })
    }

    func testHelpAndVersionDoNotCreateLibraryOrRequestScreens() async throws {
        let directory = try temporaryDirectory()
        let library = directory.appendingPathComponent("UnusedVault")
        for arguments in [["help"], ["--help"], ["screenshot", "--help"], ["record", "--help"], ["export", "--help"], ["export-images", "--help"], ["displays", "--help"], ["permissions", "--help"], ["collage", "--help"], ["stitch", "--help"], ["vault", "list", "--help"]] {
            let result = try await execute(["--library", library.path] + arguments, in: directory)
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.output.isEmpty)
            XCTAssertTrue(result.output.contains("clipato"))
            XCTAssertFalse(result.output.contains("FrameVault"))
        }
        for command in ["version", "--version"] {
            let result = try await execute([command], in: directory)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output, AppVersion.displayName + "\n")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testInvalidArgumentsReturnTwoBeforePermissionsOrFileWrites() async throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("output.png")
        let invalid: [[String]] = [
            ["unknown"],
            ["screenshot", "--output", output.path, "--tag", "red"],
            ["screenshot", "--output", output.path, "--rect", "1,2,30,40"],
            ["screenshot", "--output", output.path, "--display", "1", "--rect", "1,2,0,40"],
            ["screenshot", "--output", output.path, "--vault", "--tag", "pink"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--tag", "pink"],
            ["stitch", "--output", output.path],
            ["stitch", "--output", output.path, "--overlaps", "1,2", "a.png", "b.png"],
            ["stitch", "--output", output.path, "--overlaps", "nan", "a.png", "b.png"],
            ["stitch", "--output", output.path, "--offsets", "1", "a.png", "b.png"],
            ["stitch", "--output", output.path, "--min-overlap", "0", "a.png", "b.png"],
            ["stitch", "--output", output.path, "--max-overlap", "-1", "a.png", "b.png"],
            ["help", "unknown"],
            ["screenshot"],
            ["screenshot", "--output", output.path, "--unknown"],
            ["screenshot", "--output", output.path, "--display", "nan"],
            ["screenshot", "--output", output.path, "--display", "1", "--region"],
            ["screenshot", "--output", output.path, "--output", output.path],
            ["collage", "--output", output.path],
            ["collage", "--output", output.path, "--mode", "unknown", "input.png"],
            ["collage", "--output", output.path, "--scale", "nan", "input.png"],
            ["collage", "--output", output.path, "--columns", "0", "input.png"],
            ["collage", "--output", output.path, "--rows", "1", "--columns", "1", "a.png", "b.png"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--fps", "3"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "unknown"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "video", "--fps", "2"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "keyframes", "--fps", "30"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "video", "--threshold", "0.025"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "video", "--max-dimension", "8192"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--mode", "video", "--max-dimension", "1"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--duration", "-1"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--duration", "inf"],
            ["record", "--output", directory.appendingPathComponent("Session").path, "--duration", "1e100"],
            ["export"],
            ["export", "session"],
            ["export", "session", "--output", output.path],
            ["export", "session", "second-session", "--output", directory.appendingPathComponent("out.mp4").path],
            ["export", "session", "--output", directory.appendingPathComponent("out.mp4").path, "--max-dimension", "1"],
            ["export", "session", "--output", directory.appendingPathComponent("out.gif").path, "--max-dimension", "0"],
            ["export", "session", "--output", directory.appendingPathComponent("out.gif").path, "--max-dimension", "4097"],
            ["export", "session", "--output", directory.appendingPathComponent("out.gif").path, "--fps", "30"],
            ["export", "session", "--vault", "--output", directory.appendingPathComponent("out.gif").path],
            ["export", "session", "--vault", "--overwrite"],
            ["export-images", "--output", directory.path],
            ["export-images", "missing.png", "--output", directory.path, "--format", "webp"],
            ["export-images", "missing.png", "--output", directory.path, "--format", "png", "--quality", "80"],
            ["export-images", "missing.png", "--output", directory.path, "--format", "jpeg", "--quality", "101"],
            ["export-images", "missing.png", "--output", directory.path, "--format", "jpeg", "--fps", "1"],
            ["export-images", "missing.png", "--output", output.path, "--format", "pdf"],
            ["export-images", "missing.png", "--output", output.path, "--zip"],
            ["export-images", "missing.png", "--output", directory.appendingPathComponent("out.mp4").path, "--format", "mp4", "--fps", "0"],
            ["export-images", "missing.png", "--output", directory.appendingPathComponent("out.gif").path, "--format", "gif", "--zip"],
            ["export-images", "missing.png", "--output", directory.appendingPathComponent("out.gif").path, "--format", "gif", "--quality", "100"],
            ["vault", "import"],
            ["vault", "list", "--unknown"],
            ["--library", directory.path, "vault", "path", "--library", directory.path]
        ]
        for arguments in invalid {
            let result = try await execute(arguments, in: directory)
            XCTAssertEqual(result.status, 2, arguments.joined(separator: " "))
            XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Session").path))

        let tooManyRows = try await execute(["collage", "--output", output.path, "--columns", "1"] + Array(repeating: "missing.png", count: 65), in: directory)
        XCTAssertEqual(tooManyRows.status, 2)
        XCTAssertTrue(tooManyRows.output.isEmpty)
    }

    func testCollageRunsWithoutScreensAndUsesSpecifiedGridSettings() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("原始.png")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let output = directory.appendingPathComponent("Nested/grid.png")
        let result = try await execute([
            "collage", "--output", output.path, "--rows=2", "--columns", "1",
            "--scale", "1", "--max-width", "3", "--max-height", "2", "--spacing", "3",
            original.path, original.path
        ], in: directory)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, output.path + "\n")
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 7)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), ["grid.png"])
    }

    func testStitchManualAlignmentWritesPixelsAndSelectedVaultTag() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let root = directory.appendingPathComponent("Vault")
        let output = directory.appendingPathComponent("long.png")
        let result = try await execute(["stitch", "--output", output.path, "--overlaps", "1", "--offsets", "1",
                                        "--vault", "--tag", "orange", "--library", root.path, source.path, source.path], in: directory)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, output.path + "\n")
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
        let library = try LibraryStore(root: root)
        let saved = try XCTUnwrap(library.images.first)
        XCTAssertEqual(saved.tag, .orange)
        XCTAssertEqual(saved.source, "长截图")
        XCTAssertEqual(saved.width, 4)
        XCTAssertEqual(saved.height, 3)
        let protected = try await execute(["stitch", "--output", output.path, "--overlaps", "0", source.path, source.path], in: directory)
        XCTAssertEqual(protected.status, 1)
        XCTAssertEqual(try LibraryStore.readImage(at: output).height, 3)
    }

    func testStitchSingleImageCanBeSavedWithoutAMatchingStep() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let output = directory.appendingPathComponent("single.png")
        let result = try await execute(["stitch", "--output", output.path, source.path], in: directory)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, output.path + "\n")
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
    }

    func testStitchDuplicateImagesAreBothPreservedWithAnExplicitNotice() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let output = directory.appendingPathComponent("long.png")
        let result = try await execute(["stitch", "--min-overlap", "1", "--output", output.path, source.path, source.path], in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, output.path + "\n")
        XCTAssertTrue(result.errors.contains("重复，保留两张原图按顺序无重叠拼接"))
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 4)
    }

    func testStitchAutomaticallyMatchesReliablePixels() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try writeFixture(to: first)
        try writeFixture(to: second, pixels: [
            0, 0, 0, 255, 255, 255, 255, 255, 128, 128, 128, 255,
            255, 0, 255, 255, 0, 255, 255, 255, 255, 255, 0, 255
        ])
        let output = directory.appendingPathComponent("matched.png")
        let result = try await execute(["stitch", "--min-overlap", "1", "--output", output.path, first.path, second.path], in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.errors.isEmpty)
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 3)
    }

    func testDefaultStitchReconstructsTextAcrossAFivePixelSeam() async throws {
        let directory = try temporaryDirectory()
        let width = 725
        let height = 253
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bitmap.setFillColor(CGColor(srgbRed: 0.97, green: 0.965, blue: 0.92, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setFillColor(CGColor(srgbRed: 0.92, green: 0.91, blue: 0.85, alpha: 1))
        bitmap.addPath(CGPath(roundedRect: CGRect(x: 445, y: 18, width: 280, height: 48),
                              cornerWidth: 14, cornerHeight: 14, transform: nil))
        bitmap.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 17, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
        ]
        let lines: [(text: String, x: Int, baseline: Int)] = [
            ("1. 保留第一张截图的完整内容。", 16, 26),
            ("2. 根据共同文字的位置拼合上下两张图片。", 16, 58),
            ("3. 接缝可以位于字形内部，无需保留整行文字。", 16, 90),
            ("只有五行像素重复时，也应恢复完整句子与其原始位置。", 16, 130),
            ("下方的新消息应当完整保留", 460, 216)
        ]
        for item in lines {
            bitmap.textPosition = CGPoint(x: item.x, y: height - item.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes)), bitmap)
        }
        let mother = try XCTUnwrap(bitmap.makeImage())
        let original = Array(UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        XCTAssertGreaterThan(stride(from: 124 * width * 4, to: 129 * width * 4, by: 4).filter { original[$0] < 100 }.count, 100,
                             "The narrow overlap must contain text strokes")
        let sources = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        for (index, url) in sources.enumerated() {
            let crop = try XCTUnwrap(mother.cropping(to: CGRect(x: 0, y: index * 124, width: width, height: 129)))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, crop, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let sourceBytes = try sources.map { try Data(contentsOf: $0) }
        let output = directory.appendingPathComponent("narrow-seam.png")
        let result = try await execute(["stitch", "--output", output.path] + sources.map(\.path), in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.errors.isEmpty, result.errors)
        XCTAssertEqual(result.output, output.path + "\n")
        let rendered = try LibraryStore.readImage(at: output)
        XCTAssertEqual(rendered.width, width)
        XCTAssertEqual(rendered.height, height)
        guard rendered.width == width, rendered.height == height else { return }
        bitmap.setBlendMode(.copy)
        bitmap.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        let actual = UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: original.count)
        if let index = original.indices.first(where: { original[$0] != actual[$0] }) {
            XCTFail("CLI stitching changed text or bubble pixel (\(index / 4 % width), \(index / 4 / width)), channel \(index % 4)")
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, sourceBytes)
    }

    func testStitchOverlapRangePreservesOutOfRangePixelsAndAcceptsExplicitLimit() async throws {
        let directory = try temporaryDirectory()
        let width = 96
        let sourceHeight = 48
        let displacement = 37
        let height = sourceHeight + displacement
        var original = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt32(x) &* 0x9e3779b1 &+ UInt32(y) &* 0x85ebca6b
                value ^= value >> 16
                value &*= 0x7feb352d
                value ^= value >> 15
                let pixel = (y * width + x) * 4
                for channel in 0..<3 { original[pixel + channel] = UInt8(truncatingIfNeeded: value >> (channel * 8)) }
            }
        }
        let sources = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        let firstPixels = Array(original.prefix(width * sourceHeight * 4))
        let secondPixels = Array(original.suffix(width * sourceHeight * 4))
        try writeFixture(to: sources[0], width: width, height: sourceHeight, pixels: firstPixels)
        try writeFixture(to: sources[1], width: width, height: sourceHeight, pixels: secondPixels)
        let sourceBytes = try sources.map { try Data(contentsOf: $0) }
        let cases: [(name: String, options: [String], expected: [UInt8])] = [
            ("default-limit", [], firstPixels + secondPixels),
            ("eleven-pixel-limit", ["--max-overlap", "11"], original),
            ("zero-overlap", ["--max-overlap", "0"], firstPixels + secondPixels),
            ("manual-overrides-range", ["--max-overlap", "0", "--overlaps", "11"], original)
        ]
        for item in cases {
            let output = directory.appendingPathComponent(item.name + ".png")
            let result = try await execute(["stitch", "--output", output.path] + item.options + sources.map(\.path), in: directory)
            XCTAssertEqual(result.status, 0, item.name + ": " + result.errors)
            XCTAssertEqual(result.output, output.path + "\n")
            let image = try LibraryStore.readImage(at: output)
            let expectedHeight = item.expected.count / (width * 4)
            XCTAssertEqual(image.width, width, item.name)
            XCTAssertEqual(image.height, expectedHeight, item.name)
            guard image.width == width, image.height == expectedHeight else { continue }
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: expectedHeight,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            bitmap.setBlendMode(.copy)
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: expectedHeight))
            let actual = UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: item.expected.count)
            if let index = item.expected.indices.first(where: { item.expected[$0] != actual[$0] }) {
                XCTFail("\(item.name) changed source pixel (\(index / 4 % width), \(index / 4 / width)), channel \(index % 4)")
            }
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, sourceBytes)
    }

    func testStitchExplicitOverlapLimitPlacesDifferentWidthPNGsUsingTheirHorizontalOffset() async throws {
        let directory = try temporaryDirectory()
        let width = 400
        let height = 240
        var original = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt32(x) &* 0x9e3779b1 &+ UInt32(y) &* 0x85ebca6b
                value ^= value >> 16
                value &*= 0x7feb352d
                value ^= value >> 15
                let pixel = (y * width + x) * 4
                for channel in 0..<3 { original[pixel + channel] = UInt8(truncatingIfNeeded: value >> (channel * 8)) }
            }
        }
        let sources = [directory.appendingPathComponent("left.png"), directory.appendingPathComponent("right.png")]
        let crops = [(x: 0, width: 300), (x: 80, width: 320)]
        for (url, crop) in zip(sources, crops) {
            var pixels: [UInt8] = []
            pixels.reserveCapacity(crop.width * height * 4)
            for row in 0..<height {
                let start = (row * width + crop.x) * 4
                pixels.append(contentsOf: original[start..<(start + crop.width * 4)])
            }
            try writeFixture(to: url, width: crop.width, height: height, pixels: pixels)
        }
        let sourceBytes = try sources.map { try Data(contentsOf: $0) }
        let output = directory.appendingPathComponent("registered.png")
        let result = try await execute(["stitch", "--max-overlap", String(height), "--output", output.path] + sources.map(\.path), in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.errors.isEmpty, result.errors)
        XCTAssertEqual(result.output, output.path + "\n")
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        guard image.width == width, image.height == height else { return }
        bitmap.setBlendMode(.copy)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let rendered = UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: original.count)
        if let index = original.indices.first(where: { original[$0] != rendered[$0] }) {
            XCTFail("CLI stitching changed source pixel (\(index / 4 % width), \(index / 4 / width)), channel \(index % 4)")
        }
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, sourceBytes)
    }

    func testStitchUnmatchedFramesRemainCompleteAndCanBeExported() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.png")
        try writeFixture(to: first)
        try writeFixture(to: second, pixels: Array(repeating: [UInt8](arrayLiteral: 0, 255, 255, 255), count: 6).flatMap { $0 })
        let output = directory.appendingPathComponent("unmatched.png")
        let result = try await execute(["stitch", "--min-overlap", "1", "--output", output.path, first.path, second.path], in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.errors.contains("未可靠对齐，保留原图按顺序无重叠拼接"))
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 4)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        bitmap.getPixel(&pixel, atX: 0, y: 3)
        XCTAssertEqual(Array(pixel.prefix(3)), [0, 255, 255])
    }

    func testStitchAcceptsNegativeOverlapAndSeparatedHorizontalPositions() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let output = directory.appendingPathComponent("gap.png")
        let result = try await execute(["stitch", "--output", output.path, "--overlaps=-5", "--offsets", "-10", source.path, source.path], in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.errors.isEmpty)
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 13)
        XCTAssertEqual(image.height, 9)
        let gap = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 5, y: 4)?.usingColorSpace(.sRGB))
        XCTAssertEqual(gap.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(gap.greenComponent, 1, accuracy: 0.001)
        XCTAssertEqual(gap.blueComponent, 1, accuracy: 0.001)
    }

    func testStitchExtremePositionsFailInCoreWithoutCreatingOutput() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.png")
        try writeFixture(to: source)
        let settings = [
            ["--overlaps", String(Int.min)],
            ["--overlaps", String(Int.max)],
            ["--overlaps", "0", "--offsets", String(Int.max)],
            ["--overlaps", "0", "--offsets", "32769"]
        ]
        for (index, setting) in settings.enumerated() {
            let output = directory.appendingPathComponent("invalid-\(index).png")
            let result = try await execute(["stitch", "--output", output.path] + setting + [source.path, source.path], in: directory)
            XCTAssertEqual(result.status, 1, result.errors)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertFalse(result.errors.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testFlowCollageAcceptsDoubleDashInputSeparator() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("source.png")
        try writeFixture(to: original)
        let output = directory.appendingPathComponent("flow.png")
        let result = try await execute(["collage", "--output", output.path, "--mode", "flow", "--columns", "1", "--spacing", "1", "--", original.path, original.path], in: directory)

        XCTAssertEqual(result.status, 0)
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 5)
    }

    func testCollagePreservesExistingOutputUnlessOverwriteIsExplicit() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("source.png")
        try writeFixture(to: original)
        let output = directory.appendingPathComponent("output.png")
        let existing = Data("existing user file".utf8)
        try existing.write(to: output)
        let arguments = ["collage", "--output", output.path, "--spacing", "0", original.path, original.path]

        let rejected = try await execute(arguments, in: directory)
        XCTAssertEqual(rejected.status, 1)
        XCTAssertTrue(rejected.output.isEmpty)
        XCTAssertEqual(try Data(contentsOf: output), existing)

        let overwritten = try await execute(arguments + ["--overwrite"], in: directory)
        XCTAssertEqual(overwritten.status, 0)
        let image = try LibraryStore.readImage(at: output)
        XCTAssertEqual(image.width, 6)
        XCTAssertEqual(image.height, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Clipato-") })
    }

    func testMissingInputReturnsOperationFailureWithoutCreatingOutput() async throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("output.png")
        let result = try await execute(["collage", "--output", output.path, directory.appendingPathComponent("missing.png").path], in: directory)

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExportGIFUsesSavedTimelineAndPreservesSourceFiles() async throws {
        let directory = try temporaryDirectory()
        let session = directory.appendingPathComponent("Session")
        let frames = session.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let imageURL = frames.appendingPathComponent("000001.png")
        try writeFixture(to: imageURL)
        let imageBytes = try Data(contentsOf: imageURL)
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 1.75, sampleRate: 2,
                                        threshold: 0.025, width: 3, height: 2,
                                        frames: [.init(file: "frames/000001.png", time: 0.125)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestBytes = try encoder.encode(manifest)
        let manifestURL = session.appendingPathComponent("manifest.json")
        try manifestBytes.write(to: manifestURL)
        let output = directory.appendingPathComponent("Export/演示.GIF")
        let unusedLibrary = directory.appendingPathComponent("UnusedVault")

        let result = try await execute(["--library", unusedLibrary.path, "export", session.path,
                                        "--output", output.path], in: directory)

        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertEqual(result.output, output.path + "\n")
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, 0, nil))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, 0, nil) as? [CFString: Any])
        let timing = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(timing[kCGImagePropertyGIFUnclampedDelayTime] as? Double), 1.75, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: imageURL), imageBytes)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedLibrary.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path), ["演示.GIF"])
    }

    func testBatchExportCLIProducesJPEGMultiPagePDFAndOneFPSGIF() async throws {
        let directory = try temporaryDirectory()
        let sources = [directory.appendingPathComponent("first.png"), directory.appendingPathComponent("second.png")]
        try writeFixture(to: sources[0])
        try writeFixture(to: sources[1], pixels: [
            255, 255, 0, 255, 0, 255, 255, 255, 255, 0, 255, 255,
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255
        ])
        let originals = try sources.map { try Data(contentsOf: $0) }
        let outputDirectory = directory.appendingPathComponent("JPEG")
        let jpeg = try await execute(["export-images"] + sources.map(\.path) + ["--format", "jpeg", "--quality", "85", "--output", outputDirectory.path], in: directory)
        XCTAssertEqual(jpeg.status, 0, jpeg.errors)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)), ["first.jpeg", "second.jpeg"])
        XCTAssertEqual(try LibraryStore.readImage(at: outputDirectory.appendingPathComponent("first.jpeg")).width, 3)

        let pdfURL = directory.appendingPathComponent("pages.pdf")
        let pdfResult = try await execute(["export-images"] + sources.map(\.path) + ["--format", "pdf", "--output", pdfURL.path], in: directory)
        XCTAssertEqual(pdfResult.status, 0, pdfResult.errors)
        let pdf = try XCTUnwrap(CGPDFDocument(pdfURL as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)

        let gifURL = directory.appendingPathComponent("pictures.gif")
        let gifResult = try await execute(["export-images"] + sources.map(\.path) + ["--format", "gif", "--fps", "1", "--output", gifURL.path], in: directory)
        XCTAssertEqual(gifResult.status, 0, gifResult.errors)
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 2)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(gif, 0, nil) as? [CFString: Any])
        let timing = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        XCTAssertEqual(try XCTUnwrap(timing[kCGImagePropertyGIFUnclampedDelayTime] as? Double), 1, accuracy: 0.001)
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originals)
    }

    func testKeyframeExportToVaultCLIImportsExternalSessionInTimelineOrderWithTag() async throws {
        let directory = try temporaryDirectory()
        let session = directory.appendingPathComponent("ExternalSession")
        let frames = session.appendingPathComponent("frames")
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let sources = [frames.appendingPathComponent("first.png"), frames.appendingPathComponent("second.png")]
        for url in sources { try writeFixture(to: url) }
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 4, sampleRate: 2,
                                        threshold: 0.025, width: 3, height: 2,
                                        frames: [.init(file: "frames/first.png", time: 0), .init(file: "frames/second.png", time: 2)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(manifest)
        try bytes.write(to: session.appendingPathComponent("manifest.json"))
        try LibraryStore.writeRecordingTag(.orange, to: session)
        let root = directory.appendingPathComponent("Vault")
        let result = try await execute(["export", session.path, "--vault", "--library", root.path], in: directory)
        XCTAssertEqual(result.status, 0, result.errors)
        XCTAssertTrue(result.output.contains("2 个关键帧"))
        let library = try LibraryStore(root: root)
        XCTAssertEqual(library.images.map(\.filename), ["first.png", "second.png"])
        XCTAssertEqual(library.images.map(\.source), ["关键帧", "关键帧"])
        XCTAssertEqual(library.images.map(\.tag), [.orange, .orange])
        XCTAssertEqual(try library.images.map { try Data(contentsOf: library.imageURL($0)) }, try sources.map { try Data(contentsOf: $0) })
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("manifest.json")), bytes)
    }

    func testExportPreservesExistingOutputWhenOverwriteIsAbsentOrInputFails() async throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("existing.mp4")
        let existing = Data("existing user video".utf8)
        try existing.write(to: output)
        let arguments = ["export", directory.appendingPathComponent("MissingSession").path, "--output", output.path]

        for flags in [[String](), ["--overwrite"]] {
            let result = try await execute(arguments + flags, in: directory)
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertEqual(try Data(contentsOf: output), existing)
        }
    }

    func testConcurrentCLIProcessesCommitOnlyOneNewOutput() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("source.png")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let binary = try isolatedProcessExecutable(in: directory)

        for round in 0..<3 {
            let output = directory.appendingPathComponent("race-\(round).png")
            var jobs: [(process: Process, gate: Pipe, errors: URL)] = []
            defer { for job in jobs where job.process.isRunning { job.process.terminate() } }
            for index in 0..<8 {
                let errors = directory.appendingPathComponent("stderr-\(round)-\(index).txt")
                XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
                let errorHandle = try FileHandle(forWritingTo: errors)
                let gate = Pipe()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                // 所有子进程先等同一个启动批次，再 exec 实际 CLI；不模拟文件写入。
                process.arguments = ["-c", "read -r start && exec \"$@\"", "Clipato race", binary.path,
                                     "collage", "--output", output.path, "--spacing", "0", original.path]
                process.standardInput = gate
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorHandle
                try process.run()
                jobs.append((process, gate, errors))
                try errorHandle.close()
            }
            for job in jobs {
                try job.gate.fileHandleForWriting.write(contentsOf: Data("go\n".utf8))
                try job.gate.fileHandleForWriting.close()
            }
            for job in jobs { job.process.waitUntilExit() }
            XCTAssertEqual(jobs.filter { $0.process.terminationStatus == 0 }.count, 1)
            for job in jobs {
                XCTAssertEqual(job.process.terminationReason, .exit)
                if job.process.terminationStatus != 0 {
                    XCTAssertEqual(job.process.terminationStatus, 1)
                    XCTAssertTrue(try String(contentsOf: job.errors, encoding: .utf8).contains("输出文件已存在"))
                }
            }
            let image = try LibraryStore.readImage(at: output)
            XCTAssertEqual(image.width, 3)
            XCTAssertEqual(image.height, 2)
        }
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".Clipato-") })
    }

    func testVaultImportAndListExposeOriginalFieldsAndKeepSourceBytes() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("Original File.PNG")
        try writeFixture(to: original)
        let originalBytes = try Data(contentsOf: original)
        let root = directory.appendingPathComponent("PrivateVault")
        let imported = try await execute(["--library", root.path, "vault", "import", original.path], in: directory)

        XCTAssertEqual(imported.status, 0)
        let importedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(imported.output.utf8)) as? [[String: Any]])
        let item = try XCTUnwrap(importedJSON.first)
        XCTAssertEqual(importedJSON.count, 1)
        XCTAssertEqual(Set(item.keys), ["id", "filename", "createdAt", "width", "height", "source"])
        XCTAssertEqual(item["filename"] as? String, "Original File.PNG")
        XCTAssertEqual(item["source"] as? String, "导入")
        XCTAssertEqual(item["width"] as? Int, 3)
        XCTAssertEqual(item["height"] as? Int, 2)
        let listed = try await execute(["vault", "list", "--json", "--library=" + root.path], in: directory)
        XCTAssertEqual(listed.status, 0)
        let listedJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]])
        XCTAssertEqual(listedJSON.first?["id"] as? String, item["id"] as? String)
        XCTAssertEqual(listedJSON.first?["filename"] as? String, "Original File.PNG")
        let library = try LibraryStore(root: root)
        let saved = try XCTUnwrap(library.images.first)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(saved)), originalBytes)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }

    func testVaultPathReportsChosenDirectoryWithoutCreatingIt() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("DoesNotExist")
        let result = try await execute(["vault", "--library", root.path, "path"], in: directory)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, root.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testVaultCorruptIndexIsAnOperationFailureAndRemainsUntouched() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let index = root.appendingPathComponent("images.json")
        let corrupt = Data("broken index".utf8)
        try corrupt.write(to: index)
        let result = try await execute(["vault", "list", "--json", "--library", root.path], in: directory)

        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), corrupt)
    }

    func testUnsafeScreenshotAndRecordingDestinationsFailBeforePermissionQueries() async throws {
        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent("already.png")
        let bytes = Data("preserve".utf8)
        try bytes.write(to: existing)
        let screenshot = try await execute(["screenshot", "--output", existing.path], in: directory)
        XCTAssertEqual(screenshot.status, 1)
        XCTAssertEqual(try Data(contentsOf: existing), bytes)

        let recording = try await execute(["record", "--output", directory.path], in: directory)
        XCTAssertEqual(recording.status, 1)
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames").path))
    }

    func testExecutableValidatesInteractiveCommandsBeforeStartingAppKit() throws {
        let directory = try temporaryDirectory()
        let existing = directory.appendingPathComponent("existing.png")
        let bytes = Data("preserve".utf8)
        try bytes.write(to: existing)
        let output = directory.appendingPathComponent("Session")
        let binary = try isolatedProcessExecutable(in: directory)
        let commands: [(arguments: [String], status: Int32, message: String)] = [
            (["record", "--output", output.path, "--fps", "3"], 2, "--fps"),
            (["record", "--output", directory.path], 1, "输出必须"),
            (["screenshot", "--region", "--output", existing.path], 1, "输出文件已存在")
        ]
        for (index, command) in commands.enumerated() {
            let errors = directory.appendingPathComponent("entry-stderr-\(index)")
            XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
            let handle = try FileHandle(forWritingTo: errors)
            let process = Process()
            process.executableURL = binary
            process.arguments = command.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = handle
            try process.run()
            try handle.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, command.status)
            XCTAssertTrue(try String(contentsOf: errors, encoding: .utf8).contains(command.message))
        }
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testInvalidRecordingRectsFailBeforeSelectionOrOutputCreation() async throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("Session")
        let base = ["record", "--output", output.path]
        let invalid: [[String]] = [
            ["--rect", "0,0,100,100"],
            ["--display", "1", "--region", "--rect", "0,0,100,100"],
            ["--display", "1", "--rect", "0,0,100"],
            ["--display", "1", "--rect", "0,0,100,100,100"],
            ["--display", "1", "--rect", "0,,100,100"],
            ["--display", "1", "--rect", "nan,0,100,100"],
            ["--display", "1", "--rect", "0,0,inf,100"],
            ["--display", "1", "--rect", "-1,0,100,100"],
            ["--display", "1", "--rect", "0,-1,100,100"],
            ["--display", "1", "--rect", "0,0,0,100"],
            ["--display", "1", "--rect", "0,0,100,-1"],
            ["--display", "1", "--rect", "1e308,0,1e308,100"]
        ]
        for options in invalid {
            let result = try await execute(base + options, in: directory)
            XCTAssertEqual(result.status, 2, options.joined(separator: " "))
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertTrue(result.errors.contains("--rect"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testRecordingRegionOptionsRejectOccupiedOutputBeforeDisplayOrPermissionQueries() async throws {
        let directory = try temporaryDirectory()
        let original = directory.appendingPathComponent("keep.txt")
        let bytes = Data("user content".utf8)
        try bytes.write(to: original)
        for options in [
            [String](),
            ["--mode", "video"],
            ["--mode", "video", "--fps", "60"],
            ["--region"],
            ["--region", "--display", "4294967295"],
            ["--rect", "0.5, 1.25, 100.75, 200.5", "--display", "4294967295"]
        ] {
            let result = try await execute(["record", "--output", directory.path] + options, in: directory)
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertTrue(result.errors.contains("录制输出必须为不存在或为空的目录"))
            XCTAssertEqual(try Data(contentsOf: original), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frames").path))
        }
    }

    private func execute(_ arguments: [String], in directory: URL, access: AutomationAccess? = nil,
                         accessLog: MCPAccessLog? = nil) async throws -> (status: Int32, output: String, errors: String) {
        let access = try access ?? AutomationAccess(defaults: accessDefaults())
        let capture = directory.appendingPathComponent("stdout-\(UUID().uuidString).txt")
        let errorCapture = directory.appendingPathComponent("stderr-\(UUID().uuidString).txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: capture.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errorCapture.path, contents: nil))
        let handle = try FileHandle(forWritingTo: capture)
        let errorHandle = try FileHandle(forWritingTo: errorCapture)
        fflush(stdout)
        fflush(stderr)
        let saved = dup(STDOUT_FILENO)
        let savedErrors = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(saved, 0)
        XCTAssertGreaterThanOrEqual(savedErrors, 0)
        XCTAssertEqual(dup2(handle.fileDescriptor, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(errorHandle.fileDescriptor, STDERR_FILENO), STDERR_FILENO)
        let status = await ClipatoCLI.run(arguments: arguments, access: access, accessLog: accessLog)
        fflush(stdout)
        fflush(stderr)
        XCTAssertEqual(dup2(saved, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(savedErrors, STDERR_FILENO), STDERR_FILENO)
        XCTAssertEqual(close(saved), 0)
        XCTAssertEqual(close(savedErrors), 0)
        try handle.close()
        try errorHandle.close()
        return (status, try String(contentsOf: capture, encoding: .utf8), try String(contentsOf: errorCapture, encoding: .utf8))
    }

    private func accessDefaults(enabled: Bool = true, privacyMode: Bool = false) throws -> UserDefaults {
        let suite = "Clipato.CLITests.\(UUID().uuidString)"
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

    private func isolatedProcessExecutable(in directory: URL) throws -> URL {
        let buildDirectory = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent()
        let suite = "Clipato.CLIProcessTests.\(UUID().uuidString)"
        let contents = directory.appendingPathComponent("CLI.app/Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Clipato")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: buildDirectory.appendingPathComponent("Clipato"), to: executable)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: buildDirectory.appendingPathComponent("Clipato_Clipato.bundle"),
                                        to: resources.appendingPathComponent("Clipato_Clipato.bundle"))
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": suite, "CFBundleExecutable": "Clipato", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        defaults.set(false, forKey: "privacyMode")
        defaults.synchronize()
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        return executable
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeFixture(to url: URL, width: Int = 3, height: Int = 2, pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
            0, 0, 0, 255, 255, 255, 255, 255, 128, 128, 128, 255
        ]) throws {
        let data = Data(pixels)
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
