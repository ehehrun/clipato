import AppKit
import ClipatoCore
import ImageIO
import XCTest
@testable import Clipato

@MainActor
final class ImageGridExportTests: XCTestCase {
    private let colors: [[UInt8]] = [
        [220, 35, 45], [30, 180, 65], [30, 75, 215],
        [235, 165, 25], [140, 40, 205], [25, 180, 190],
        [180, 75, 35], [95, 140, 210], [185, 65, 130]
    ]

    func testFourTilesSkipSourceGapAndExportInReadingOrderWithoutChangingOriginal() async throws {
        let root = try directory()
        let input = try fixture(root, name: "four.png", divisions: 2, gap: 8)
        let original = try Data(contentsOf: input)
        let options = ImageGridOptions(divisions: 2, tileSize: 256, gap: 8)
        let output = root.appendingPathComponent("tiles")

        try await BatchImageExporter.export(images: [input], output: output, options: .init(grid: options))

        let expected = ["four-grid-01.png", "four-grid-02.png", "four-grid-03.png", "four-grid-04.png"]
        XCTAssertEqual(BatchImageExporter.gridFilenames(input, options: options, format: .png), expected)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), Set(expected))
        for (index, name) in expected.enumerated() {
            let image = try read(output.appendingPathComponent(name))
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 256)
            for point in [(0, 0), (128, 128), (255, 255)] {
                XCTAssertEqual(try pixel(image, x: point.0, y: point.1), colors[index])
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging(root)
    }

    func testNineJPEGFilesUseTheChosenAliasNameAndPreserveRowOrder() async throws {
        let root = try directory()
        let input = try fixture(root, name: "actual.png", divisions: 3)
        let original = try Data(contentsOf: input)
        let alias = root.appendingPathComponent("chosen.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let options = ImageGridOptions(divisions: 3, tileSize: 256)
        let output = root.appendingPathComponent("nine")

        try await BatchImageExporter.export(images: [alias], output: output,
                                            options: .init(imageFormat: .jpeg, quality: 100, grid: options))

        let names = BatchImageExporter.gridFilenames(alias, options: options, format: .jpeg)
        XCTAssertEqual(names.first, "chosen-grid-01.jpeg")
        XCTAssertEqual(names.last, "chosen-grid-09.jpeg")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), Set(names))
        for (index, name) in names.enumerated() {
            let url = output.appendingPathComponent(name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 256)
            XCTAssertEqual(image.height, 256)
            let actual = try pixel(image, x: 128, y: 128)
            for channel in 0..<3 { XCTAssertEqual(Int(actual[channel]), Int(colors[index][channel]), accuracy: 3) }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), input.path)
        try assertNoStaging(root)
    }

    func testNonsquareOrUndersizedInputDoesNotPublishAnyTiles() async throws {
        let root = try directory()
        let square = try fixture(root, name: "square.png", divisions: 2)
        let image = try read(square)
        let nonsquare = root.appendingPathComponent("nonsquare.png")
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 512, height: 500)))
        try ImageFormatStep.execute(image: cropped, format: .png).write(to: nonsquare)

        for (index, input) in [nonsquare, square].enumerated() {
            let output = root.appendingPathComponent("failed-\(index)")
            let options = ImageGridOptions(divisions: index == 0 ? 2 : 3, tileSize: 256)
            do {
                try await BatchImageExporter.export(images: [input], output: output, options: .init(grid: options))
                XCTFail("An invalid grid source must not produce partially exported tiles.")
            } catch is ImageGridError {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
        try assertNoStaging(root)
    }

    func testExplicitSquareCropAllowsNonsquareInput() async throws {
        let root = try directory()
        let square = try fixture(root, name: "square.png", divisions: 2)
        let image = try read(square)
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 512, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        let input = root.appendingPathComponent("wide.png")
        try ImageFormatStep.execute(image: try XCTUnwrap(context.makeImage()), format: .png).write(to: input)
        let output = root.appendingPathComponent("cropped")

        try await BatchImageExporter.export(images: [input], output: output,
            options: .init(grid: .init(divisions: 2, tileSize: 256, crop: CGRect(x: 0, y: 0, width: 512, height: 512))))

        for index in 0..<4 {
            let url = output.appendingPathComponent(String(format: "wide-grid-%02d.png", index + 1))
            XCTAssertEqual(try pixel(read(url), x: 128, y: 128), colors[index])
        }
        try assertNoStaging(root)
    }

    func testEXIFRotationUsesOrientedTopLeftCropCoordinatesAndTileOrder() async throws {
        let root = try directory()
        let square = try fixture(root, name: "source.png", divisions: 3)
        let portrait = try XCTUnwrap(read(square).cropping(to: CGRect(x: 0, y: 0, width: 512, height: 768)))
        let input = root.appendingPathComponent("portrait.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "public.tiff" as CFString, 1, nil))
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 6]
        CGImageDestinationAddImage(destination, portrait, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(metadata[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(metadata[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertEqual(metadata[kCGImagePropertyPixelHeight] as? Int, 768)
        let original = try Data(contentsOf: input)
        let output = root.appendingPathComponent("rotated")

        try await BatchImageExporter.export(images: [input], output: output,
            options: .init(grid: .init(divisions: 2, tileSize: 256, crop: CGRect(x: 256, y: 0, width: 512, height: 512))))

        // The clockwise rotation makes a 3-column landscape image; crop its right two columns.
        let expectedColors = [colors[3], colors[0], colors[4], colors[1]]
        for index in 0..<4 {
            let url = output.appendingPathComponent(String(format: "portrait-grid-%02d.png", index + 1))
            let tile = try read(url)
            XCTAssertEqual(tile.width, 256)
            XCTAssertEqual(tile.height, 256)
            for point in [(0, 0), (128, 128), (255, 255)] {
                XCTAssertEqual(try pixel(tile, x: point.0, y: point.1), expectedColors[index])
            }
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging(root)
    }

    func testSmallNonsquareSourceExportsNineTilesAndKeepsTheWholeOddSizedCrop() async throws {
        let root = try directory()
        let input = try smallCropFixture(root)
        let original = try Data(contentsOf: input)
        let output = root.appendingPathComponent("small-nine")
        let options = ImageGridOptions(divisions: 3, tileSize: 60, crop: CGRect(x: 165, y: 0, width: 245, height: 245))

        try await BatchImageExporter.export(images: [input], output: output, options: .init(grid: options))

        let names = BatchImageExporter.gridFilenames(input, options: options, format: .png)
        XCTAssertEqual(names.count, 9)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), Set(names))
        for (index, name) in names.enumerated() {
            let tile = try read(output.appendingPathComponent(name))
            XCTAssertEqual(tile.width, 60)
            XCTAssertEqual(tile.height, 60)
            XCTAssertEqual(try pixel(tile, x: 30, y: 30), colors[index])
        }
        let first = try read(output.appendingPathComponent(names[0]))
        XCTAssertEqual(try pixel(first, x: 2, y: 30), [255, 80, 20])
        XCTAssertEqual(try pixel(first, x: 30, y: 2), [40, 180, 40])
        let last = try read(output.appendingPathComponent(names[8]))
        let rightEdge = try pixel(last, x: 57, y: 30)
        // Fractional resampling can round a color channel by one level.
        for (actual, expected) in zip(rightEdge, [20, 220, 220]) {
            XCTAssertEqual(Int(actual), expected, accuracy: 1)
        }
        XCTAssertEqual(try pixel(last, x: 30, y: 57), [190, 35, 210])
        // A black final source column/row must contribute to the last output pixels.
        XCTAssertLessThan(try pixel(last, x: 59, y: 30)[1], 215)
        XCTAssertLessThan(try pixel(last, x: 30, y: 59)[0], 185)
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging(root)
    }

    func testFourTilesAcceptAnOddSizedCropAndProduceExactSquareOutputs() async throws {
        let root = try directory()
        let input = try smallCropFixture(root)
        let original = try Data(contentsOf: input)
        let output = root.appendingPathComponent("small-four")
        let options = ImageGridOptions(divisions: 2, tileSize: 122, crop: CGRect(x: 165, y: 0, width: 245, height: 245))

        try await BatchImageExporter.export(images: [input], output: output, options: .init(grid: options))

        let names = BatchImageExporter.gridFilenames(input, options: options, format: .png)
        XCTAssertEqual(names.count, 4)
        let expected = [colors[0], colors[2], colors[6], colors[8]]
        for (index, name) in names.enumerated() {
            let tile = try read(output.appendingPathComponent(name))
            XCTAssertEqual(tile.width, 122)
            XCTAssertEqual(tile.height, 122)
            XCTAssertEqual(try pixel(tile, x: 61, y: 61), expected[index])
        }
        let first = try read(output.appendingPathComponent(names[0]))
        XCTAssertEqual(try pixel(first, x: 2, y: 61), [255, 80, 20])
        XCTAssertEqual(try pixel(first, x: 61, y: 2), [40, 180, 40])
        let last = try read(output.appendingPathComponent(names[3]))
        XCTAssertEqual(try pixel(last, x: 118, y: 61), [20, 220, 220])
        XCTAssertEqual(try pixel(last, x: 61, y: 118), [190, 35, 210])
        XCTAssertLessThan(try pixel(last, x: 121, y: 61)[1], 215)
        XCTAssertLessThan(try pixel(last, x: 61, y: 121)[0], 185)
        XCTAssertEqual(try Data(contentsOf: input), original)
        try assertNoStaging(root)
    }

    func testExistingTargetIsNotOverwrittenAndNoOtherTilesArePublished() async throws {
        let root = try directory()
        let input = try fixture(root, name: "original.png", divisions: 2)
        let output = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent("original-grid-03.png")
        let saved = Data("previous export".utf8)
        try saved.write(to: target)

        do {
            try await BatchImageExporter.export(images: [input], output: output,
                                                options: .init(grid: .init(divisions: 2, tileSize: 256)))
            XCTFail("Replacing an existing tile requires explicit overwrite.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("导出文件已存在，请选择其他位置或允许覆盖：\(target.path)"))
        }

        XCTAssertEqual(try Data(contentsOf: target), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [target.lastPathComponent])
        try assertNoStaging(root)
    }

    func testOverwriteCannotReplaceAHardLinkToTheOriginal() async throws {
        let root = try directory()
        let input = try fixture(root, name: "source.png", divisions: 2)
        let original = try Data(contentsOf: input)
        let output = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent("source-grid-01.png")
        try FileManager.default.linkItem(at: input, to: target)

        do {
            try await BatchImageExporter.export(images: [input], output: output,
                                                options: .init(grid: .init(divisions: 2, tileSize: 256)), overwrite: true)
            XCTFail("Overwrite must still protect the source's filesystem identity.")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("导出不能覆盖原始图片：\(target.path)"))
        }

        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: target), original)
        try assertNoStaging(root)
    }

    func testInvalidSourceCountOrExportModesDoNotCreateAnOutput() async throws {
        let root = try directory()
        let first = try fixture(root, name: "first.png", divisions: 2)
        let second = try fixture(root, name: "second.png", divisions: 2)
        let grid = ImageGridOptions(divisions: 2, tileSize: 256)
        let cases: [([URL], BatchExportOptions, String)] = [
            ([first, second], .init(grid: grid), L("宫格切图仅支持单张图片。")),
            ([first], .init(mode: .zip, grid: grid), L("宫格切图请使用独立文件导出。")),
            ([first], .init(mode: .video, grid: grid), L("宫格切图请使用独立文件导出。")),
            ([first], .init(imageFormat: .pdf, grid: grid), L("宫格切图仅支持 PNG 或 JPEG。")),
            ([first], .init(processing: .init(tool: .convert), grid: grid), L("宫格切图与图片处理不能同时执行。"))
        ]
        for (index, entry) in cases.enumerated() {
            let output = root.appendingPathComponent("invalid-\(index)")
            do {
                try await BatchImageExporter.export(images: entry.0, output: output, options: entry.1)
                XCTFail("An invalid export request must fail before writing files.")
            } catch {
                XCTAssertEqual(error.localizedDescription, entry.2)
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
        }
        try assertNoStaging(root)
    }

    func testCancellationDoesNotPublishTiles() async throws {
        let root = try directory()
        let input = try fixture(root, name: "source.png", divisions: 2)
        let output = root.appendingPathComponent("cancelled")
        let task = Task {
            try await BatchImageExporter.export(images: [input], output: output,
                                                options: .init(grid: .init(divisions: 2, tileSize: 256)))
        }
        task.cancel()
        do { try await task.value; XCTFail("A cancelled export must not publish output.") }
        catch is CancellationError { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        try assertNoStaging(root)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ImageGridExport.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func fixture(_ root: URL, name: String, divisions: Int, gap: Int = 0) throws -> URL {
        let side = divisions * 256 + (divisions - 1) * gap
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let row = y / (256 + gap), column = x / (256 + gap)
                let color = y % (256 + gap) < 256 && x % (256 + gap) < 256 ? colors[row * divisions + column] : [255, 0, 255]
                let offset = (y * side + x) * 4
                for channel in 0..<3 { bytes[offset + channel] = color[channel] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = root.appendingPathComponent(name)
        try ImageFormatStep.execute(image: image, format: .png).write(to: url)
        return url
    }

    private func smallCropFixture(_ root: URL) throws -> URL {
        let width = 576, height = 245
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var color: [UInt8] = [240, 15, 240]
                if (165..<410).contains(x) {
                    let localX = x - 165
                    color = colors[(y * 3 / 245) * 3 + localX * 3 / 245]
                    if localX < 10 { color = [255, 80, 20] }
                    if localX >= 235 { color = [20, 220, 220] }
                    if y < 10 { color = [40, 180, 40] }
                    if y >= 235 { color = [190, 35, 210] }
                    if localX == 244 || y == 244 { color = [0, 0, 0] }
                }
                let offset = (y * width + x) * 4
                for channel in 0..<3 { bytes[offset + channel] = color[channel] }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = root.appendingPathComponent("small.png")
        try ImageFormatStep.execute(image: image, format: .png).write(to: url)
        return url
    }

    private func read(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let onePixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(onePixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return [bytes[0], bytes[1], bytes[2]]
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
