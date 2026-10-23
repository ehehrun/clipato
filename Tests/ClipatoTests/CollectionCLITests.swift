import AppKit
import Darwin
import XCTest
@testable import Clipato

@MainActor
final class CollectionCLITests: XCTestCase {
    func testHelpDoesNotOpenOrCreateLibrary() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("UnusedVault")
        for command in [["help", "collection"], ["collection", "--help"], ["collection", "add", "--help"]] {
            let result = try await execute(["--library", root.path] + command, in: directory)
            XCTAssertEqual(result.status, 0, result.errors)
            XCTAssertTrue(result.output.contains("保留全部媒体"))
            XCTAssertFalse(result.output.contains("--parent"))
            XCTAssertFalse(result.output.contains("--recursive"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testCreateRenameMoveAndDeletePreserveMediaAndExposeOriginalFields() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        let item = try library.addImage(fixture(), source: "截图")
        let original = try Data(contentsOf: library.imageURL(item))
        await library.cancelStorageWorkAndWait()
        let first = try await execute(["collection", "create", "工作", "--library", root.path], in: directory)
        XCTAssertEqual(first.status, 0, first.errors)
        let work = try XCTUnwrap(UUID(uuidString: first.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let created = try await execute(["--library", root.path, "collection", "create", "项目 A"], in: directory)
        XCTAssertEqual(created.status, 0, created.errors)
        let project = try XCTUnwrap(UUID(uuidString: created.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        let renamed = try await execute(["collection", "--library", root.path, "rename", project.uuidString, "项目素材"], in: directory)
        XCTAssertEqual(renamed.status, 0, renamed.errors)

        let listed = try await execute(["collection", "list", "--json", "--library", root.path], in: directory)
        XCTAssertEqual(listed.status, 0, listed.errors)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(listed.output.utf8)) as? [[String: Any]])
        let jsonProject = try XCTUnwrap(json.first { $0["id"] as? String == project.uuidString })
        XCTAssertEqual(Set(jsonProject.keys), ["id", "name", "parentID", "position"])
        XCTAssertTrue(jsonProject["parentID"] is NSNull)
        XCTAssertEqual(jsonProject["name"] as? String, "项目素材")
        let moved = try await execute(["collection", "move", project.uuidString, "--before", work.uuidString, "--library", root.path], in: directory)
        XCTAssertEqual(moved.status, 0, moved.errors)
        let afterMove = try LibraryStore(root: root).collections
        XCTAssertEqual(afterMove.map(\.id), [project, work])
        XCTAssertEqual(afterMove.map(\.position), [0, 1])
        XCTAssertTrue(afterMove.allSatisfy { $0.parentID == nil })
        let movedToEnd = try await execute(["collection", "move", project.uuidString, "--library", root.path], in: directory)
        XCTAssertEqual(movedToEnd.status, 0, movedToEnd.errors)
        XCTAssertEqual(try LibraryStore(root: root).collections.map(\.id), [work, project])

        let added = try await execute(["collection", "add", project.uuidString, "image:\(item.id)", "--library", root.path], in: directory)
        XCTAssertEqual(added.status, 0, added.errors)
        let deleted = try await execute(["collection", "delete", project.uuidString, "--library", root.path], in: directory)
        XCTAssertEqual(deleted.status, 0, deleted.errors)
        XCTAssertEqual(try LibraryStore(root: root).images, [item])
        XCTAssertEqual(try LibraryStore(root: root).collections.map(\.id), [work])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), original)
    }

    func testMixedAssetsRoundTripAndRemovalOnlyChangesOneCollection() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        let work = try library.createCollection(name: "工作")
        let project = try library.createCollection(name: "项目")
        let item = try library.addImage(fixture(), source: "截图")
        let videoDirectory = root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: false)
        let video = videoDirectory.appendingPathComponent("recording.mp4")
        let videoBytes = Data("published video".utf8)
        try videoBytes.write(to: video)
        let sessionDirectory = root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 1, sampleRate: 1, threshold: 0.025,
                                        width: 2, height: 2, frames: [.init(file: "frame.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestBytes = try encoder.encode(manifest)
        try manifestBytes.write(to: sessionDirectory.appendingPathComponent("manifest.json"))
        await library.cancelStorageWorkAndWait()
        let refs = ["image:\(item.id)", "session:\(manifest.id)", "video:\(video.path)"]
        for folder in [work.id, project.id] {
            let result = try await execute(["collection", "add", folder.uuidString] + refs + ["--library", root.path], in: directory)
            XCTAssertEqual(result.status, 0, result.errors)
        }
        let listed = try await execute(["collection", "items", project.id.uuidString, "--json", "--library", root.path], in: directory)
        XCTAssertEqual(listed.status, 0, listed.errors)
        let assets = try JSONDecoder().decode([CollectionAsset].self, from: Data(listed.output.utf8))
        XCTAssertEqual(Set(assets), [.image(item.id), .session(manifest.id), .video(video)])
        let removed = try await execute(["collection", "remove", work.id.uuidString] + refs + ["--library", root.path], in: directory)
        XCTAssertEqual(removed.status, 0, removed.errors)
        let direct = try await execute(["collection", "items", work.id.uuidString, "--library", root.path], in: directory)
        XCTAssertEqual(direct.status, 0, direct.errors)
        XCTAssertTrue(direct.output.isEmpty)
        let retained = try await execute(["collection", "items", project.id.uuidString, "--library", root.path], in: directory)
        XCTAssertEqual(retained.status, 0, retained.errors)
        XCTAssertEqual(Set(retained.output.split(separator: "\n").map(String.init)), Set(refs))
        XCTAssertEqual(try Data(contentsOf: video), videoBytes)
        XCTAssertEqual(try Data(contentsOf: sessionDirectory.appendingPathComponent("manifest.json")), manifestBytes)
    }

    func testInvalidArgumentsAreRejectedBeforeCreatingLibrary() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("UnusedVault")
        let id = UUID().uuidString
        let cases = [
            ["list", "--recursive"], ["list", "unexpected"], ["create"], ["create", "A", "B"],
            ["create", "A", "--parent", id], ["rename", id], ["rename", "wrong", "A"],
            ["move", id, "--parent", id], ["move", id, "--before", "wrong"],
            ["delete", "wrong"], ["items", "wrong"], ["items", id, "--parent", id], ["items", id, "--recursive"],
            ["add", id], ["add", id, "image:wrong"], ["add", id, "session:wrong"],
            ["add", id, "video:"], ["add", id, "unknown:value"], ["remove", id, "image"],
            ["help", "unexpected"], ["unknown"], ["list", "--json=false"], ["list", "--json", "--json"]
        ]
        for arguments in cases {
            let result = try await execute(["--library", root.path, "collection"] + arguments, in: directory)
            XCTAssertEqual(result.status, 2, arguments.joined(separator: " ") + ": " + result.errors)
            XCTAssertTrue(result.output.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testMissingFolderOrMediaFailWithoutChangingCollections() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("Vault")
        let library = try LibraryStore(root: root)
        let work = try library.createCollection(name: "工作")
        let project = try library.createCollection(name: "项目")
        let cases = [
            ["items", UUID().uuidString], ["delete", UUID().uuidString],
            ["add", project.id.uuidString, "image:\(UUID())"],
            ["move", work.id.uuidString, "--before", UUID().uuidString]
        ]
        for arguments in cases {
            let result = try await execute(["collection"] + arguments + ["--library", root.path], in: directory)
            XCTAssertEqual(result.status, 1, result.errors)
            XCTAssertTrue(result.output.isEmpty)
        }
        let restored = try LibraryStore(root: root)
        XCTAssertEqual(restored.collections, library.collections)
        XCTAssertEqual(restored.collectionMembers, library.collectionMembers)
        await library.cancelStorageWorkAndWait()
    }

    private func execute(_ arguments: [String], in directory: URL) async throws -> (status: Int32, output: String, errors: String) {
        let suite = "Clipato.CollectionCLITests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        defaults.synchronize()
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.synchronize()
        }
        let output = directory.appendingPathComponent("stdout-\(UUID()).txt")
        let errors = directory.appendingPathComponent("stderr-\(UUID()).txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errors.path, contents: nil))
        let handle = try FileHandle(forWritingTo: output)
        let errorHandle = try FileHandle(forWritingTo: errors)
        fflush(stdout)
        fflush(stderr)
        let savedOutput = dup(STDOUT_FILENO)
        let savedErrors = dup(STDERR_FILENO)
        XCTAssertEqual(dup2(handle.fileDescriptor, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(errorHandle.fileDescriptor, STDERR_FILENO), STDERR_FILENO)
        let status = await ClipatoCLI.run(arguments: arguments, access: AutomationAccess(defaults: defaults))
        fflush(stdout)
        fflush(stderr)
        XCTAssertEqual(dup2(savedOutput, STDOUT_FILENO), STDOUT_FILENO)
        XCTAssertEqual(dup2(savedErrors, STDERR_FILENO), STDERR_FILENO)
        XCTAssertEqual(close(savedOutput), 0)
        XCTAssertEqual(close(savedErrors), 0)
        try handle.close()
        try errorHandle.close()
        return (status, try String(contentsOf: output, encoding: .utf8), try String(contentsOf: errors, encoding: .utf8))
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CollectionCLITests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
