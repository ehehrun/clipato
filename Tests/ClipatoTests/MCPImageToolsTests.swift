import AppKit
import CryptoKit
import ClipatoCore
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class MCPImageToolsTests: XCTestCase {
    func testRenameDefinitionsMatchTheMinimumSelectionWithoutCreatingALibrary() async throws {
        let root = try directory()
        let image = try write(noise(width: 8, height: 8), root.appendingPathComponent("single.png"))
        let original = try Data(contentsOf: image)
        let library = root.appendingPathComponent("Unused Library")
        for name in ["batch_rename_preview", "batch_rename"] {
            let definition = try XCTUnwrap(MCPImageTools.definitions.first { $0["name"] as? String == name })
            let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let files = try XCTUnwrap(properties["files"] as? [String: Any])
            XCTAssertEqual(files["minItems"] as? Int, 2)
            do {
                _ = try await MCPImageTools.call(name: name, arguments: ["files": [image.path]], library: library)
                XCTFail("A single image must be rejected before creating the library.")
            } catch MCPError.invalidArguments { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
            XCTAssertEqual(try Data(contentsOf: image), original)
        }
    }

    func testImageToolsPublishRealCompressedResizedAndConvertedFilesWithoutChangingInputs() async throws {
        let root = try directory()
        let files = try ["first.png", "second.png"].map { try write(noise(width: 160, height: 120), root.appendingPathComponent($0)) }
        let originals = try files.map { try Data(contentsOf: $0) }
        let library = root.appendingPathComponent("Library")
        let compressed = try await MCPImageTools.call(name: "image_compress", arguments: [
            "files": files.map(\.path), "output": root.appendingPathComponent("compressed").path,
            "targetBytes": 2048
        ], library: library)
        for path in try XCTUnwrap(compressed["files"] as? [String]) {
            XCTAssertLessThanOrEqual(try Data(contentsOf: URL(fileURLWithPath: path)).count, 2048)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let resized = try await MCPImageTools.call(name: "image_resize", arguments: [
            "files": files.map(\.path), "output": root.appendingPathComponent("resized").path, "format": "webp", "quality": 100,
            "sizes": [["width": 64, "height": 64, "mode": "pad"], ["width": 32, "height": 24, "mode": "crop"]]
        ], library: library)
        let paths = try XCTUnwrap(resized["files"] as? [String])
        XCTAssertEqual(paths.count, 4)
        for (index, path) in paths.enumerated() {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, index.isMultiple(of: 2) ? 64 : 32)
            XCTAssertEqual(image.height, index.isMultiple(of: 2) ? 64 : 24)
        }
        let converted = try await MCPImageTools.call(name: "image_convert", arguments: [
            "files": [files[0].path], "output": root.appendingPathComponent("converted").path, "format": "webp", "quality": 100
        ], library: library)
        let convertedURL = URL(fileURLWithPath: try XCTUnwrap((converted["files"] as? [String])?.first))
        let convertedSource = try XCTUnwrap(CGImageSourceCreateWithURL(convertedURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(convertedSource) as String?, "org.webmproject.webp")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(convertedSource, 0, nil))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 120)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, originals)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path), "File-only tools must not create or open the vault.")
        try assertNoStaging(root)
    }

    func testFailedLaterInputDoesNotPublishEarlierOutputsAndExistingFilesAreNotOverwritten() async throws {
        let root = try directory()
        let input = try write(noise(width: 32, height: 24), root.appendingPathComponent("source.png"))
        let broken = root.appendingPathComponent("broken.png")
        try Data("invalid image".utf8).write(to: broken)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let notes = output.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: notes)
        do {
            _ = try await MCPImageTools.call(name: "image_convert", arguments: [
                "files": [input.path, broken.path], "output": output.path
            ], library: root.appendingPathComponent("Library"))
            XCTFail("A corrupt second input must fail the whole batch.")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["notes.txt"])
        }
        let occupied = output.appendingPathComponent("source.jpeg")
        try Data("old output".utf8).write(to: occupied)
        do {
            _ = try await MCPImageTools.call(name: "image_convert", arguments: [
                "files": [input.path], "output": output.path
            ], library: root.appendingPathComponent("Library"))
            XCTFail("An existing destination must require a different output path.")
        } catch { XCTAssertEqual(try String(contentsOf: occupied, encoding: .utf8), "old output") }
        try assertNoStaging(root)
    }

    func testGridRequiresSquareCropAndSkipsGapPixelsInPublishedTileOrder() async throws {
        let root = try directory()
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        var bytes = [UInt8](repeating: 255, count: 10 * 6 * 4)
        for y in 0..<6 {
            for x in 0..<10 {
                let localX = x - 2
                let color = localX >= 0 && localX < 6 && localX % 4 < 2 && y % 4 < 2
                    ? colors[(y / 4) * 2 + localX / 4] : [255, 0, 255]
                for channel in 0..<3 { bytes[(y * 10 + x) * 4 + channel] = color[channel] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 10, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 40,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = try write(image, root.appendingPathComponent("grid.png"))
        var arguments: [String: Any] = ["files": [input.path], "output": root.appendingPathComponent("tiles").path,
                                       "divisions": 2, "gap": 2]
        do {
            _ = try await MCPImageTools.call(name: "image_grid", arguments: arguments, library: root.appendingPathComponent("Library"))
            XCTFail("A nonsquare image requires an explicit square crop.")
        } catch ImageGridError.requiresCrop {}
        arguments["crop"] = ["x": 2, "y": 0, "width": 6, "height": 6]
        let result = try await MCPImageTools.call(name: "image_grid", arguments: arguments, library: root.appendingPathComponent("Library"))
        let files = try XCTUnwrap(result["files"] as? [String])
        XCTAssertEqual(files.count, 4)
        for (index, path) in files.enumerated() {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
            let tile = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(tile.width, 2)
            XCTAssertEqual(tile.height, 2)
            let context = try bitmap(width: 2, height: 2)
            context.draw(tile, in: CGRect(x: 0, y: 0, width: 2, height: 2))
            let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            for pixel in 0..<4 {
                for channel in 0..<3 { XCTAssertEqual(pixels[pixel * 4 + channel], colors[index][channel]) }
            }
        }
        arguments["tileSize"] = 3
        arguments["output"] = root.appendingPathComponent("oversized").path
        do {
            _ = try await MCPImageTools.call(name: "image_grid", arguments: arguments, library: root.appendingPathComponent("Library"))
            XCTFail("Explicit tile dimensions must fail if the crop is too small, rather than silently shrinking.")
        } catch ImageGridError.sourceTooSmall(let requiredSide) { XCTAssertEqual(requiredSide, 8) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        try assertNoStaging(root)
    }

    func testDuplicateAndSimilarityToolsReturnEvidenceWithoutRemovingInputs() async throws {
        let root = try directory()
        let first = try write(noise(width: 96, height: 72), root.appendingPathComponent("original.png"))
        let copy = root.appendingPathComponent("copy.png")
        try FileManager.default.copyItem(at: first, to: copy)
        let unrelated = try write(solid(width: 96, height: 72, red: 1, green: 0, blue: 0), root.appendingPathComponent("red.png"))
        let originals = try [first, copy, unrelated].map { try Data(contentsOf: $0) }
        let duplicate = try await MCPImageTools.call(name: "files_find_duplicates", arguments: ["files": [first.path, copy.path, unrelated.path]], library: root.appendingPathComponent("Library"))
        let group = try XCTUnwrap((duplicate["groups"] as? [[String: Any]])?.first)
        XCTAssertEqual(group["urls"] as? [String], [first.path, copy.path])
        XCTAssertEqual(group["fileSize"] as? Int64, Int64(originals[0].count))
        XCTAssertEqual(group["sha256"] as? String, SHA256.hash(data: originals[0]).map { String(format: "%02x", $0) }.joined())
        let similar = try await MCPImageTools.call(name: "images_find_similar", arguments: ["files": [first.path, copy.path, unrelated.path]], library: root.appendingPathComponent("Library"))
        let matches = try XCTUnwrap(similar["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0]["first"] as? String, first.path)
        XCTAssertEqual(matches[0]["second"] as? String, copy.path)
        XCTAssertEqual(matches[0]["kind"] as? String, "similar")
        XCTAssertGreaterThan(try XCTUnwrap(matches[0]["score"] as? Double), 0.9)
        XCTAssertEqual(try [first, copy, unrelated].map { try Data(contentsOf: $0) }, originals)
    }

    func testRenamePreviewAndApplyPreserveVaultIDsTagsMembershipAndCallerOrder() async throws {
        let root = try directory()
        let library = try LibraryStore(root: root.appendingPathComponent("Library"))
        let collection = try library.createCollection(name: "素材")
        let first = try library.addImage(solid(width: 8, height: 8, red: 1, green: 0, blue: 0), source: "截图", tag: .orange, collectionID: collection.id)
        let second = try library.addImage(solid(width: 8, height: 8, red: 0, green: 0, blue: 1), source: "截图", tag: .blue, collectionID: collection.id)
        await library.cancelStorageWorkAndWait()
        let ordered = [second, first]
        let files = ordered.map(library.imageURL)
        let originalBytes = try files.map { try Data(contentsOf: $0) }
        let arguments: [String: Any] = ["files": files.map(\.path), "prefix": "素材_", "start": 7, "increment": 2, "digits": 2]
        let preview = try await MCPImageTools.call(name: "batch_rename_preview", arguments: arguments, library: library.root)
        XCTAssertEqual(preview["filenames"] as? [String], ["素材_07.png", "素材_09.png"])
        XCTAssertEqual(preview["applied"] as? Bool, false)
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, originalBytes)
        let applied = try await MCPImageTools.call(name: "batch_rename", arguments: arguments, library: library.root)
        XCTAssertEqual(applied["applied"] as? Bool, true)
        let reloaded = try LibraryStore(root: library.root)
        await reloaded.cancelStorageWorkAndWait()
        XCTAssertEqual(reloaded.assets(in: collection.id), Set(ordered.map { .image($0.id) }))
        for (index, original) in ordered.enumerated() {
            let actual = try XCTUnwrap(reloaded.images.first { $0.id == original.id })
            XCTAssertEqual(actual.filename, index == 0 ? "素材_07.png" : "素材_09.png")
            XCTAssertEqual(actual.tag, original.tag)
            XCTAssertEqual(actual.createdAt, original.createdAt)
            XCTAssertEqual(try Data(contentsOf: reloaded.imageURL(actual)), originalBytes[index])
            XCTAssertFalse(FileManager.default.fileExists(atPath: files[index].path))
        }
    }

    func testExternalRenameAndManagedPathProtections() async throws {
        let root = try directory()
        let library = try LibraryStore(root: root.appendingPathComponent("Library"))
        let stored = try library.addImage(solid(width: 4, height: 4, red: 1, green: 0, blue: 0), source: "截图")
        await library.cancelStorageWorkAndWait()
        let first = try write(noise(width: 8, height: 8), root.appendingPathComponent("first.png"))
        let second = try write(noise(width: 8, height: 8), root.appendingPathComponent("second.png"))
        let bytes = try [second, first].map { try Data(contentsOf: $0) }
        let result = try await MCPImageTools.call(name: "batch_rename", arguments: ["files": [second.path, first.path], "prefix": "Item_", "digits": 2], library: library.root)
        let destinations = try XCTUnwrap(result["destinations"] as? [String])
        XCTAssertEqual(destinations.map { URL(fileURLWithPath: $0).lastPathComponent }, ["Item_01.png", "Item_02.png"])
        XCTAssertEqual(try destinations.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, bytes)
        let linked = root.appendingPathComponent("linked.png")
        try FileManager.default.linkItem(at: library.imageURL(stored), to: linked)
        let unindexed = try write(noise(width: 8, height: 8), library.root.appendingPathComponent("unindexed.png"))
        for invalid in [linked, unindexed] {
            do {
                _ = try await MCPImageTools.call(name: "batch_rename", arguments: ["files": [invalid.path, destinations[0]]], library: library.root)
                XCTFail("Unindexed managed files and vault hard links must not use the external rename path.")
            } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path)) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(stored).path))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.MCPImageTools.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func bitmap(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func noise(width: Int, height: Int) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt64 = 1742
        for index in 0..<(width * height) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            pixels[index * 4] = UInt8(truncatingIfNeeded: seed >> 24)
            pixels[index * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 32)
            pixels[index * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 40)
            pixels[index * 4 + 3] = 255
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try bitmap(width: width, height: height)
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    @discardableResult
    private func write(_ image: CGImage, _ url: URL) throws -> URL {
        try ImageFormatStep.execute(image: image, format: .png).write(to: url)
        return url
    }

    private func assertNoStaging(_ root: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            XCTAssertFalse(child.lastPathComponent.hasPrefix(".clipato-export-"))
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try assertNoStaging(child) }
        }
    }
}
