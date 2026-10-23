import AppKit
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class MCPAppToolsTests: XCTestCase {
    func testOverwriteCannotBypassTrashApprovalThroughManagedPathsOrFileLinks() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("vault")
        let external = try fixture(root, name: "external.png", red: 0.2)
        let store = try LibraryStore(root: library, enforceStorageQuota: false)
        try store.importImages([external])
        let image = try XCTUnwrap(store.images.first)
        let original = store.imageURL(image)
        let bytes = try Data(contentsOf: original)
        let symbolic = root.appendingPathComponent("symbolic.png")
        let linked = root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: original)
        try FileManager.default.linkItem(at: original, to: linked)
        for output in [original, symbolic, linked] {
            do {
                _ = try await MCPAppTools.call(name: "collage", arguments: ["files": [external.path], "output": output.path, "overwrite": true], library: library)
                XCTFail("Managed originals must not be overwritten through another MCP tool")
            } catch { XCTAssertTrue(error.localizedDescription.contains("cannot overwrite vault")) }
        }
        do {
            _ = try await MCPAppTools.call(name: "export_images", arguments: ["files": [external.path], "output": library.path, "overwrite": true], library: library)
            XCTFail("An export must not replace a directory containing the vault")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cannot overwrite vault")) }
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(store.images.map(\.id), [image.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent("library.sqlite").path))
        let safeOutput = try fixture(root, name: "safe-output.png", red: 0.8)
        _ = try await MCPAppTools.call(name: "collage", arguments: ["files": [external.path], "output": safeOutput.path, "overwrite": true], library: library)
        XCTAssertEqual(try LibraryStore.readImage(at: safeOutput).width, 32)
        await store.cancelStorageWorkAndWait()
    }

    func testMCPImportPreservesOlderImagesWhenAutomaticCleanupIsConfigured() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("vault")
        let source = try fixture(root, name: "keep-original.png", red: 0.3)
        let store = try LibraryStore(root: library, enforceStorageQuota: false)
        try store.importImages([source])
        let original = try XCTUnwrap(store.images.first)
        let originalURL = store.imageURL(original)
        let bytes = try Data(contentsOf: originalURL)
        try store.updateStoragePolicy(.init(maximumBytes: 1, automaticallyRemoveOldestImages: true,
                                            protectTaggedImages: false, protectCollectedImages: false, keepRecentDays: 0))
        await store.refreshStorageUsage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        await store.cancelStorageWorkAndWait()
        let another = try fixture(root, name: "new.png", red: 0.8)
        _ = try await MCPAppTools.call(name: "vault_import", arguments: ["files": [another.path]], library: library)
        let result = try await MCPAppTools.call(name: "vault_list", arguments: [:], library: library)
        let images: [VaultImage] = try decode(result["images"]!)
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.contains { $0.id == original.id })
        XCTAssertEqual(try Data(contentsOf: originalURL), bytes)
    }

    func testVaultImportCollectionMembershipAndDeletePreserveOriginalMedia() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("vault")
        let source = try fixture(root, name: "original.png", red: 0.4)
        let original = try Data(contentsOf: source)
        let imported = try await MCPAppTools.call(name: "vault_import", arguments: ["files": [source.path]], library: library)
        let images: [VaultImage] = try decode(imported["images"]!)
        let image = try XCTUnwrap(images.first)
        XCTAssertEqual(image.filename, "original.png")
        XCTAssertEqual(image.source, "导入")
        XCTAssertEqual(image.width, 32)
        let paths = try XCTUnwrap(imported["paths"] as? [String])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), original)

        let firstResult = try await MCPAppTools.call(name: "collection_create", arguments: ["name": "项目"], library: library)
        let secondResult = try await MCPAppTools.call(name: "collection_create", arguments: ["name": "参考"], library: library)
        let first: AssetCollection = try decode(firstResult["collection"]!)
        let second: AssetCollection = try decode(secondResult["collection"]!)
        for collection in [first, second] {
            _ = try await MCPAppTools.call(name: "collection_add", arguments: ["id": collection.id.uuidString, "assets": ["image:\(image.id)"]], library: library)
            let result = try await MCPAppTools.call(name: "collection_items", arguments: ["id": collection.id.uuidString], library: library)
            let members: [CollectionAsset] = try decode(result["assets"]!)
            XCTAssertEqual(members, [.image(image.id)])
        }
        _ = try await MCPAppTools.call(name: "collection_rename", arguments: ["id": first.id.uuidString, "name": "项目更新"], library: library)
        _ = try await MCPAppTools.call(name: "collection_delete", arguments: ["id": first.id.uuidString], library: library)
        let listed = try await MCPAppTools.call(name: "collection_list", arguments: [:], library: library)
        let collections: [AssetCollection] = try decode(listed["collections"]!)
        XCTAssertEqual(collections.map(\.id), [second.id])
        let remaining = try await MCPAppTools.call(name: "collection_items", arguments: ["id": second.id.uuidString], library: library)
        let members: [CollectionAsset] = try decode(remaining["assets"]!)
        XCTAssertEqual(members, [.image(image.id)])
        _ = try await MCPAppTools.call(name: "collection_remove", arguments: ["id": second.id.uuidString, "assets": ["image:\(image.id)"]], library: library)
        let vault = try await MCPAppTools.call(name: "vault_list", arguments: ["offset": 0, "limit": 1], library: library)
        let surviving: [VaultImage] = try decode(vault["images"]!)
        XCTAssertEqual(surviving.map(\.id), [image.id])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), original)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testCollageStitchAndTransactionalExportUseRealImages() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("vault")
        let first = try fixture(root, name: "a.png", red: 0.2)
        let second = try fixture(root, name: "b.png", red: 0.8)
        let files = [first.path, second.path]
        let original = try Data(contentsOf: first)
        let collage = root.appendingPathComponent("collage.png")
        _ = try await MCPAppTools.call(name: "collage", arguments: ["files": files, "output": collage.path, "columns": 2, "rows": 1, "spacing": 4], library: library)
        let joined = try LibraryStore.readImage(at: collage)
        XCTAssertEqual(joined.width, 68)
        XCTAssertEqual(joined.height, 24)
        let stitched = root.appendingPathComponent("stitched.png")
        let result = try await MCPAppTools.call(name: "stitch", arguments: ["files": files, "output": stitched.path, "maximumOverlap": 0], library: library)
        XCTAssertEqual(result["height"] as? Int, 48)
        XCTAssertEqual(try LibraryStore.readImage(at: stitched).width, 32)
        let output = root.appendingPathComponent("exported")
        _ = try await MCPAppTools.call(name: "export_images", arguments: ["files": files, "output": output.path, "format": "png"], library: library)
        XCTAssertEqual(try LibraryStore.readImage(at: output.appendingPathComponent("a.png")).width, 32)
        let pdf = root.appendingPathComponent("pages.pdf")
        _ = try await MCPAppTools.call(name: "export_images", arguments: ["files": files, "output": pdf.path, "format": "pdf"], library: library)
        XCTAssertEqual(try XCTUnwrap(CGPDFDocument(pdf as CFURL)).numberOfPages, 2)
        do {
            _ = try await MCPAppTools.call(name: "collage", arguments: ["files": files, "output": collage.path], library: library)
            XCTFail("An existing output must not be overwritten implicitly.")
        } catch { XCTAssertTrue(error.localizedDescription.contains(collage.path)) }
        do {
            _ = try await MCPAppTools.call(name: "collage", arguments: ["files": files, "output": first.path, "overwrite": true], library: library)
            XCTFail("An explicit overwrite must still protect source images.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("source")) }
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path), "File-only tools must not initialize or change the vault.")
    }

    func testRecordingListGIFExportAndFrameImportPreserveSession() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("vault")
        let sessionID = UUID()
        let session = library.appendingPathComponent("Sessions/\(sessionID)")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        _ = try fixture(session, name: "0001.png", red: 0.2)
        _ = try fixture(session, name: "0002.png", red: 0.8)
        let manifest = KeyframeManifest(id: sessionID, createdAt: Date(timeIntervalSince1970: 100), duration: 2, sampleRate: 2, threshold: 0.025, width: 32, height: 24,
            frames: [.init(file: "0001.png", time: 0), .init(file: "0002.png", time: 1)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(manifest)
        try bytes.write(to: session.appendingPathComponent("manifest.json"))
        let listed = try await MCPAppTools.call(name: "recordings_list", arguments: [:], library: library)
        let sessions = try XCTUnwrap(listed["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0]["id"] as? String, sessionID.uuidString)
        XCTAssertEqual(sessions[0]["width"] as? Int, 32)
        XCTAssertEqual(sessions[0]["frameCount"] as? Int, 2)
        XCTAssertNil(sessions[0]["manifest"], "Normal listing must not return potentially huge frame arrays.")
        let full = try await MCPAppTools.call(name: "recordings_list", arguments: ["includeManifest": true, "limit": 1], library: library)
        let fullSessions = try XCTUnwrap(full["sessions"] as? [[String: Any]])
        let decodedManifest: KeyframeManifest = try decode(XCTUnwrap(fullSessions[0]["manifest"]))
        XCTAssertEqual(decodedManifest.frames.map(\.file), ["0001.png", "0002.png"])
        let gif = root.appendingPathComponent("session.gif")
        _ = try await MCPAppTools.call(name: "export_recording", arguments: ["directory": session.path, "output": gif.path], library: library)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 2)
        let imported = try await MCPAppTools.call(name: "export_recording", arguments: ["directory": session.path, "vault": true], library: library)
        XCTAssertEqual(imported["count"] as? Int, 2)
        let result = try await MCPAppTools.call(name: "vault_list", arguments: [:], library: library)
        let images: [VaultImage] = try decode(result["images"]!)
        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(Set(images.map(\.source)), ["关键帧"])
        XCTAssertEqual(try Data(contentsOf: session.appendingPathComponent("manifest.json")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.appendingPathComponent("0001.png").path))

        let secondID = UUID()
        let later = library.appendingPathComponent("Sessions/\(secondID)")
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
        let laterManifest = KeyframeManifest(id: secondID, createdAt: Date(timeIntervalSince1970: 200), duration: 2, sampleRate: 2,
            threshold: 0.025, width: 32, height: 24, frames: manifest.frames)
        try encoder.encode(laterManifest).write(to: later.appendingPathComponent("manifest.json"))
        let page = try await MCPAppTools.call(name: "recordings_list", arguments: ["offset": 1, "limit": 1], library: library)
        let pageSessions = try XCTUnwrap(page["sessions"] as? [[String: Any]])
        XCTAssertEqual(page["totalSessions"] as? Int, 2)
        XCTAssertEqual(pageSessions.count, 1)
        XCTAssertEqual(pageSessions[0]["id"] as? String, sessionID.uuidString)
        let emptyPage = try await MCPAppTools.call(name: "recordings_list", arguments: ["offset": 2, "limit": 1], library: library)
        XCTAssertEqual((emptyPage["sessions"] as? [[String: Any]])?.count, 0)
    }

    func testInvalidInputsAreRejectedBeforeScreenCaptureOrVaultMutation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("unused-vault")
        let output = root.appendingPathComponent("output.png").path
        let cases: [(String, [String: Any])] = [
            ("screenshot", ["output": output, "unknown": true]),
            ("screenshot", ["output": output, "rect": ["x": 0, "y": 0, "width": 20, "height": 20]]),
            ("screenshot", ["output": output, "displayID": true]),
            ("screenshot", ["output": "relative.png"]),
            ("screenshot", ["output": output, "tag": "red"]),
            ("record", ["output": root.appendingPathComponent("recording").path]),
            ("record", ["output": root.appendingPathComponent("recording").path, "duration": 0]),
            ("record", ["output": root.appendingPathComponent("recording").path, "duration": 1, "mode": "video", "threshold": 0.02]),
            ("record", ["output": root.appendingPathComponent("recording").path, "duration": 1, "mode": "keyframes", "fps": 30]),
            ("export_images", ["files": [output], "output": output, "format": "png", "quality": 80]),
            ("export_images", ["files": [output], "output": output, "format": "mp4", "zip": false]),
            ("collage", ["files": [output], "output": output, "mode": "flow", "rows": 2]),
            ("stitch", ["files": [output, output], "output": output, "offsets": [1]]),
            ("collection_create", ["name": "Nested", "parentID": UUID().uuidString]),
            ("collection_add", ["id": UUID().uuidString, "assets": ["folder:\(UUID())"]])
        ]
        for (name, arguments) in cases {
            do {
                _ = try await MCPAppTools.call(name: name, arguments: arguments, library: library)
                XCTFail("Accepted invalid arguments for \(name): \(arguments)")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    func testCatalogHasStrictSchemasAndTruthfulCollectionDeletionAnnotation() throws {
        let definitions = MCPAppTools.definitions
        XCTAssertEqual(Set(definitions.compactMap { $0["name"] as? String }).count, definitions.count)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(definitions))
        for definition in definitions {
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        }
        let delete = try XCTUnwrap(definitions.first { $0["name"] as? String == "collection_delete" })
        XCTAssertEqual((delete["annotations"] as? [String: Any])?["destructiveHint"] as? Bool, true)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-AppTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(_ root: URL, name: String, red: CGFloat) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let url = root.appendingPathComponent(name)
        try LibraryStore.writePNG(XCTUnwrap(context.makeImage()), to: url)
        return url
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
