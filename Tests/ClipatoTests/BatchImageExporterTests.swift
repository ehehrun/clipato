import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

final class BatchImageExporterTests: XCTestCase {
    func testPNGPreservesPixelsAndDuplicateNamesInSelectedDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = try ["a/same.png", "b/same.png"].enumerated().map { try fixture(root, name: $0.element, seed: $0.offset) }
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: output.appendingPathComponent("notes.txt"))
        try await BatchImageExporter.export(images: inputs, output: output, options: .init())
        for (index, name) in ["same.png", "same-2.png"].enumerated() {
            XCTAssertEqual(try pixels(read(output.appendingPathComponent(name))), try pixels(read(inputs[index])))
        }
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("notes.txt"), encoding: .utf8), "keep")
        try assertNoStaging(root)
    }

    func testJPEGQualityChangesRealCompressionAndDimensions() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "noise.png", width: 256, height: 192, noisy: true)
        var sizes: [Int] = []
        for quality in [10, 100] {
            let output = root.appendingPathComponent("quality-\(quality)")
            try await BatchImageExporter.export(images: [input], output: output, options: .init(imageFormat: .jpeg, quality: quality))
            let jpeg = output.appendingPathComponent("noise.jpeg")
            sizes.append(try Data(contentsOf: jpeg).count)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source), UTType.jpeg.identifier as CFString)
            let image = try read(jpeg)
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 192)
        }
        XCTAssertGreaterThan(sizes[1], sizes[0] * 2)
    }

    func testExistingExportFolderDoesNotRequireWritingItsParent() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        let output = root.appendingPathComponent("writable")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        try await BatchImageExporter.export(images: [input], output: output, options: .init())
        XCTAssertEqual(try pixels(read(output.appendingPathComponent("source.png"))), try pixels(read(input)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["source.png"])
    }

    func testPDFHasOrderedPagesNativeDimensionsAndCompressionQuality() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let inputs = [try fixture(root, name: "a.png", width: 256, height: 192, noisy: true),
                      try fixture(root, name: "b.png", width: 90, height: 140)]
        var sizes: [Int] = []
        for quality in [10, 100] {
            let output = root.appendingPathComponent("quality-\(quality).pdf")
            try await BatchImageExporter.export(images: inputs, output: output, options: .init(imageFormat: .pdf, quality: quality))
            let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
            XCTAssertEqual(pdf.numberOfPages, 2)
            XCTAssertEqual(try XCTUnwrap(pdf.page(at: 1)).getBoxRect(.mediaBox).size, CGSize(width: 256, height: 192))
            XCTAssertEqual(try XCTUnwrap(pdf.page(at: 2)).getBoxRect(.mediaBox).size, CGSize(width: 90, height: 140))
            sizes.append(try Data(contentsOf: output).count)
        }
        XCTAssertGreaterThan(sizes[1], sizes[0] * 2)
    }

    func testZIPContainsConvertedPicturesAndPDFOptionContainsOneDocument() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = [try fixture(root, name: "一.png"), try fixture(root, name: "二.png", seed: 1)]
        for format in [BatchImageFormat.jpeg, .pdf] {
            let zip = root.appendingPathComponent("\(format.rawValue).zip")
            try await BatchImageExporter.export(images: images, output: zip, options: .init(mode: .zip, imageFormat: format, quality: 80))
            let extracted = root.appendingPathComponent("unzip-\(format.rawValue)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, extracted.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let names = try FileManager.default.contentsOfDirectory(atPath: extracted.path)
            if format == .pdf {
                XCTAssertEqual(names, ["图片.pdf"])
                XCTAssertEqual(try XCTUnwrap(CGPDFDocument(extracted.appendingPathComponent("图片.pdf") as CFURL)).numberOfPages, 2)
            } else {
                XCTAssertEqual(Set(names), Set(["一.jpeg", "二.jpeg"]))
                XCTAssertEqual(try read(extracted.appendingPathComponent("一.jpeg")).width, 64)
            }
        }
        try assertNoStaging(root)
    }

    func testMP4AtOneFPSPreservesOrderDurationAndFitsDifferentSizesOnWhite() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = [try fixture(root, name: "wide.png", width: 64, height: 32),
                      try fixture(root, name: "tall.png", width: 32, height: 64, seed: 1)]
        let output = root.appendingPathComponent("slides.mp4")
        try await BatchImageExporter.export(images: images, output: output, options: .init(mode: .video, fps: 1))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 2, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 64, height: 64))
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(trackOutput)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = trackOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {
                times.append(CMTimeGetSeconds(sample.presentationTimeStamp))
            }
        }
        XCTAssertEqual(times, [0, 1])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for index in images.indices {
            let result = try await generator.image(at: CMTime(seconds: Double(index), preferredTimescale: 600))
            let bytes = try pixels(result.image)
            assertPixel(bytes, width: 64, x: 3, y: 3, expected: [255, 255, 255], tolerance: 8)
            assertPixel(bytes, width: 64, x: 32, y: 24, expected: index == 0 ? [230, 30, 20] : [20, 180, 40], tolerance: 15)
        }
    }

    func testGIFAtFiveFPSKeepsAllFramesAspectRatioAndWhitePadding() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = [try fixture(root, name: "wide.png", width: 64, height: 32),
                      try fixture(root, name: "tall.png", width: 32, height: 64, seed: 1)]
        let output = root.appendingPathComponent("slides.gif")
        try await BatchImageExporter.export(images: images, output: output, options: .init(mode: .video, videoFormat: .gif, fps: 5))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for index in images.indices {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double), 0.2, accuracy: 0.001)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            let bytes = try pixels(image)
            assertPixel(bytes, width: 64, x: 3, y: 3, expected: [255, 255, 255])
            assertPixel(bytes, width: 64, x: 32, y: 24, expected: index == 0 ? [230, 30, 20] : [20, 180, 40])
        }
    }

    func testInvalidInputAndFailedOverwriteLeaveExistingFilesUntouched() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        let missing = root.appendingPathComponent("missing.png")
        let output = root.appendingPathComponent("existing.pdf")
        let previous = Data("user file".utf8)
        try previous.write(to: output)
        await expectFailure { try await BatchImageExporter.export(images: [input], output: output, options: .init(imageFormat: .pdf)) }
        await expectFailure { try await BatchImageExporter.export(images: [input, missing], output: output, options: .init(imageFormat: .pdf), overwrite: true) }
        XCTAssertEqual(try Data(contentsOf: output), previous)
        let corrupt = root.appendingPathComponent("broken.png")
        try Data(contentsOf: input).dropLast(25).write(to: corrupt)
        await expectFailure { try await BatchImageExporter.export(images: [input, corrupt], output: root.appendingPathComponent("new"), options: .init()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new").path))
        try assertNoStaging(root)
    }

    func testSourceProtectionIncludesSymlinkAndExistingDirectoryTargets() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        let original = try Data(contentsOf: input)
        let link = root.appendingPathComponent("link.gif")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
        await expectFailure { try await BatchImageExporter.export(images: [input], output: root, options: .init(), overwrite: true) }
        await expectFailure { try await BatchImageExporter.export(images: [input], output: link, options: .init(mode: .video, videoFormat: .gif), overwrite: true) }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testCaseInsensitiveFilenameCannotOverwriteSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.PNG")
        let lowercase = root.appendingPathComponent("source.png")
        guard FileManager.default.fileExists(atPath: lowercase.path) else { throw XCTSkip("此卷区分文件名大小写。") }
        let original = try Data(contentsOf: input)
        do {
            try await BatchImageExporter.export(images: [input], output: root, options: .init(), overwrite: true)
            XCTFail("导出覆盖了仅扩展名大小写不同的源文件")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不能覆盖原始图片"), "\(error)") }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging(root)
    }

    func testHardLinkedTargetCannotOverwriteSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        let output = root.appendingPathComponent("source-link.gif")
        try FileManager.default.linkItem(at: input, to: output)
        let original = try Data(contentsOf: input)
        do {
            try await BatchImageExporter.export(images: [input], output: output,
                options: .init(mode: .video, videoFormat: .gif), overwrite: true)
            XCTFail("导出替换了原图的硬链接")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不能覆盖原始图片"), "\(error)") }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: output), original)
        try assertNoStaging(root)
    }

    func testCommitConflictRollsBackEarlierReplacementsWithoutRemovingUserDirectory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let images = [try fixture(root, name: "a.png"), try fixture(root, name: "b.png")]
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let existing = output.appendingPathComponent("a.png")
        let old = Data("old user's picture".utf8)
        try old.write(to: existing)
        let conflict = output.appendingPathComponent("b.png")
        let created = expectation(description: "created concurrent destination")
        await expectFailure {
            try await BatchImageExporter.export(images: images, output: output, options: .init(), overwrite: true) { value in
                if value == 0 {
                    do { try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: false) }
                    catch { XCTFail("\(error)") }
                    created.fulfill()
                }
            }
        }
        await fulfillment(of: [created], timeout: 1)
        XCTAssertEqual(try Data(contentsOf: existing), old)
        XCTAssertTrue(try conflict.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        try assertNoStaging(root)
    }

    func testCancellationRemovesStagingAndDoesNotPublish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        let output = root.appendingPathComponent("cancelled.gif")
        let started = expectation(description: "started")
        let task = Task {
            try await BatchImageExporter.export(images: Array(repeating: input, count: 10_000), output: output,
                options: .init(mode: .video, videoFormat: .gif)) { if $0 == 0 { started.fulfill() } }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export completed") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoStaging(root)
    }

    func testInvalidOptionsDoNotCreateOutput() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try fixture(root, name: "source.png")
        for options in [BatchExportOptions(quality: 0), .init(quality: 101), .init(mode: .video, fps: 0), .init(mode: .video, fps: 31)] {
            await expectFailure { try await BatchImageExporter.export(images: [input], output: root.appendingPathComponent("output"), options: options) }
        }
        await expectFailure { try await BatchImageExporter.export(images: [], output: root.appendingPathComponent("output"), options: .init()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("output").path))
    }

    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-batch-export-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false)
        return result
    }

    private func fixture(_ root: URL, name: String, width: Int = 64, height: Int = 48, seed: Int = 0, noisy: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let color: [UInt8] = seed == 0 ? [230, 30, 20] : [20, 180, 40]
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var random: UInt32 = 42
        for index in 0..<(width * height) {
            for channel in 0..<3 {
                random = random &* 1_664_525 &+ 1_013_904_223
                bytes[index * 4 + channel] = noisy ? UInt8(random >> 24) : color[channel]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func read(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func assertPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, expected: [UInt8], tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[(y * width + x) * 4 + channel]) - Int(expected[channel])), tolerance, file: file, line: line)
        }
    }

    private func assertNoStaging(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".clipato-export-") }, file: file, line: line)
    }

    private func expectFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch { XCTAssertFalse(error is CancellationError, file: file, line: line) }
    }
}
