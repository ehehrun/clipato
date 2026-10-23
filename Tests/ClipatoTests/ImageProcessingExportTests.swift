import AppKit
import ClipatoCore
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class ImageProcessingExportTests: XCTestCase {
    func testMultipleSpecificationsConvertEveryInputAndPreserveOriginals() async throws {
        let root = try directory()
        let first = try fixture(root, name: "a/same.png")
        let second = try fixture(root, name: "b/same.png")
        let originals = try [first, second].map { try Data(contentsOf: $0) }
        var processing = ImageProcessingOptions(tool: .resize)
        processing.format = .webp
        processing.quality = 100
        processing.sizes = [.init(width: 64, height: 64, mode: .pad), .init(width: 32, height: 24, mode: .crop)]
        let output = root.appendingPathComponent("processed")

        try await BatchImageExporter.export(images: [first, second], output: output, options: .init(processing: processing))

        let expected = ["same-64x64-pad.webp", "same-32x24-crop.webp", "same-64x64-pad-2.webp", "same-32x24-crop-2.webp"]
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), Set(expected))
        for (index, name) in expected.enumerated() {
            let url = output.appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, index.isMultiple(of: 2) ? 64 : 32)
            XCTAssertEqual(image.height, index.isMultiple(of: 2) ? 64 : 24)
        }
        for (index, url) in [first, second].enumerated() { XCTAssertEqual(try Data(contentsOf: url), originals[index]) }
        try assertNoStaging(root)
    }

    func testTargetSizeIsMetForEveryRealExportedFile() async throws {
        let root = try directory()
        let inputs = try ["noise-a.png", "noise-b.png"].map { try fixture(root, name: $0, width: 256, height: 192) }
        var processing = ImageProcessingOptions(tool: .compress)
        processing.targetBytes = 2_048
        let output = root.appendingPathComponent("compressed")

        try await BatchImageExporter.export(images: inputs, output: output, options: .init(processing: processing))

        for name in ["noise-a.jpeg", "noise-b.jpeg"] {
            let url = output.appendingPathComponent(name)
            XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2_048)
            XCTAssertNotNil(CGImageSourceCreateWithURL(url as CFURL, nil))
        }
        try assertNoStaging(root)
    }

    func testSymbolicLinkUsesTheInputNameShownInTheOutputPlan() async throws {
        let root = try directory()
        let input = try fixture(root, name: "actual-name.png")
        let alias = root.appendingPathComponent("chosen-name.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let processing = ImageProcessingOptions(tool: .convert)
        XCTAssertEqual(BatchImageExporter.processedFilenames([alias], options: processing), ["chosen-name.jpeg"])
        let output = root.appendingPathComponent("output")

        try await BatchImageExporter.export(images: [alias], output: output, options: .init(processing: processing))

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["chosen-name.jpeg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), input.path)
    }

    func testLaterInvalidInputDoesNotPublishEarlierProcessedFiles() async throws {
        let root = try directory()
        let first = try fixture(root, name: "valid.png")
        let bad = root.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: bad)
        let output = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: output.appendingPathComponent("notes.txt"))

        do {
            try await BatchImageExporter.export(images: [first, bad], output: output,
                                                options: .init(processing: .init(tool: .convert)))
            XCTFail("A corrupt later image must fail the batch.")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["notes.txt"])
            XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("notes.txt"), encoding: .utf8), "keep")
        }
        try assertNoStaging(root)
    }

    func testExistingProcessedOutputIsNotReplaced() async throws {
        let root = try directory()
        let input = try fixture(root, name: "original.png")
        let output = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent("original.jpeg")
        try Data("previous output".utf8).write(to: target)

        do {
            try await BatchImageExporter.export(images: [input], output: output,
                                                options: .init(processing: .init(tool: .convert)))
            XCTFail("Existing outputs require an explicit overwrite request.")
        } catch { XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "previous output") }
        try assertNoStaging(root)
    }

    func testInvalidOrDuplicateSourceAdditionKeepsTheCurrentDraft() throws {
        let root = try directory()
        let name = "Clipato.ImageProcessingExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(root: root.appendingPathComponent("Library"), shortcuts: ShortcutManager(defaults: defaults))
        let first = try fixture(root, name: "first.png")
        let second = try fixture(root, name: "second.png")
        let broken = root.appendingPathComponent("broken.png")
        try Data("broken".utf8).write(to: broken)
        try model.appendImageExportSources([first, first])
        XCTAssertEqual(model.batchExportImages, [first])
        XCTAssertThrowsError(try model.appendImageExportSources([second, broken]))
        XCTAssertEqual(model.batchExportImages, [first])
        try model.appendImageExportSources([second, first])
        XCTAssertEqual(model.batchExportImages, [first, second])
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ImageProcessingExport.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(_ root: URL, name: String, width: Int = 80, height: Int = 40) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt64 = 173
        for index in 0..<(width * height) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            bytes[index * 4] = UInt8(truncatingIfNeeded: seed >> 24)
            bytes[index * 4 + 1] = UInt8(truncatingIfNeeded: seed >> 32)
            bytes[index * 4 + 2] = UInt8(truncatingIfNeeded: seed >> 40)
            bytes[index * 4 + 3] = 255
        }
        let data = try ImageFormatStep.execute(image: try XCTUnwrap(context.makeImage()), format: .png)
        try data.write(to: url)
        return url
    }

    private func assertNoStaging(_ root: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix(".clipato-export-") })
        for child in children {
            let url = root.appendingPathComponent(child)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try assertNoStaging(url) }
        }
    }
}
