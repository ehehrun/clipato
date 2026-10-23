import CoreGraphics
import XCTest
@testable import ClipatoCore

final class CollageTests: XCTestCase {
    func testGridPreservesAspectRatioCentersImagesAndLeavesUnusedCellsWhite() throws {
        let wide = image(width: 40, height: 20, red: 1, green: 0, blue: 0)
        let tall = image(width: 10, height: 40, red: 0, green: 0, blue: 1)
        let settings = CollageSettings(columns: 2, rows: 2, scale: 0.5, maxWidth: 100, maxHeight: 100, spacing: 4)
        let result = try CollageRenderer.render(images: [wide, tall], settings: settings)

        XCTAssertEqual(result.width, 44)
        XCTAssertEqual(result.height, 44)
        XCTAssertEqual(pixel(result, x: 5, y: 10), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 5, y: 1), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, x: 32, y: 10), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 25, y: 10), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, x: 10, y: 30), [255, 255, 255, 255])
        XCTAssertEqual(wide.width, 40)
        XCTAssertEqual(wide.height, 20)
    }

    func testElementLimitsApplyTogetherWithScale() throws {
        let source = image(width: 80, height: 40, red: 1, green: 0, blue: 0)
        let result = try CollageRenderer.render(
            images: [source],
            settings: CollageSettings(columns: 1, rows: 1, scale: 2, maxWidth: 60, maxHeight: 20, spacing: 0)
        )
        XCTAssertEqual(result.width, 40)
        XCTAssertEqual(result.height, 20)
    }

    func testFlowUsesActualWidthsAndWrapsInSelectionOrder() throws {
        let images = [
            image(width: 20, height: 10, red: 1, green: 0, blue: 0),
            image(width: 5, height: 20, red: 0, green: 1, blue: 0),
            image(width: 5, height: 10, red: 0, green: 0, blue: 1),
            image(width: 20, height: 5, red: 0, green: 0, blue: 0)
        ]
        let result = try CollageRenderer.render(
            images: images,
            settings: CollageSettings(mode: .flow, columns: 2, rows: 1, maxWidth: 100, maxHeight: 100, spacing: 2)
        )
        XCTAssertEqual(result.width, 34)
        XCTAssertEqual(result.height, 27)
        XCTAssertEqual(pixel(result, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 23, y: 15), [0, 255, 0, 255])
        XCTAssertEqual(pixel(result, x: 30, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 24), [0, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 21), [255, 255, 255, 255])
    }

    func testRejectsEmptySelectionAndInsufficientGrid() {
        XCTAssertThrowsError(try CollageRenderer.render(images: [], settings: CollageSettings())) {
            guard case CollageError.emptySelection = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let source = image(width: 1, height: 1, red: 1, green: 0, blue: 0)
        XCTAssertThrowsError(try CollageRenderer.render(images: [source, source], settings: CollageSettings(columns: 1, rows: 1))) {
            guard case CollageError.insufficientGrid(let capacity, let count) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertEqual(capacity, 1)
            XCTAssertEqual(count, 2)
        }
    }

    func testRejectsInvalidSettingsBeforeRendering() {
        let source = image(width: 1, height: 1, red: 1, green: 0, blue: 0)
        let invalid = [
            CollageSettings(columns: 0),
            CollageSettings(rows: 65),
            CollageSettings(scale: .nan),
            CollageSettings(scale: .infinity),
            CollageSettings(scale: 0),
            CollageSettings(maxWidth: 0),
            CollageSettings(maxHeight: 8_193),
            CollageSettings(spacing: -1),
            CollageSettings(spacing: 513)
        ]
        for settings in invalid {
            XCTAssertThrowsError(try CollageRenderer.render(images: [source], settings: settings)) {
                guard case CollageError.invalidSetting = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testRejectsCanvasDimensionAndPixelLimits() {
        let source = image(width: 10, height: 10, red: 1, green: 0, blue: 0)
        let cases = [
            CollageSettings(columns: 64, rows: 1, spacing: 512),
            CollageSettings(columns: 64, rows: 64, spacing: 150)
        ]
        for settings in cases {
            XCTAssertThrowsError(try CollageRenderer.render(images: [source], settings: settings)) {
                guard case CollageError.canvasTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testTinyImagesRemainVisibleAtMinimumScale() throws {
        let source = image(width: 1, height: 1, red: 1, green: 0, blue: 0)
        let result = try CollageRenderer.render(images: [source], settings: CollageSettings(columns: 1, rows: 1, scale: 0.05))
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
        XCTAssertEqual(pixel(result, x: 0, y: 0), [255, 0, 0, 255])
    }

    func testRawImageRowsKeepTheirOrientationAndTransparencyUsesWhiteBackground() throws {
        let bytes = Data([
            255, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 255, 255, 0, 0, 255, 255
        ])
        let source = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let result = try CollageRenderer.render(images: [source], settings: CollageSettings(columns: 1, rows: 1))

        XCTAssertEqual(pixel(result, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 0), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, x: 0, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 1), [0, 0, 255, 255])
    }

    func testLayoutKeepsUnusedGridRowsAndImageIndices() throws {
        let images = [
            image(width: 40, height: 20, red: 1, green: 0, blue: 0),
            image(width: 10, height: 40, red: 0, green: 0, blue: 1)
        ]
        let layout = try CollageRenderer.layout(
            images: images,
            settings: CollageSettings(columns: 2, rows: 2, scale: 0.5, maxWidth: 100, maxHeight: 100, spacing: 4)
        )
        XCTAssertEqual(layout.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(layout.placements, [
            CollagePlacement(imageIndex: 0, frame: CGRect(x: 0, y: 5, width: 20, height: 10)),
            CollagePlacement(imageIndex: 1, frame: CGRect(x: 31.5, y: 0, width: 5, height: 20))
        ])
    }

    func testFreeCollageUsesArrayOrderForOverlappingLayers() throws {
        let images = [
            image(width: 4, height: 4, red: 1, green: 0, blue: 0),
            image(width: 4, height: 4, red: 0, green: 0, blue: 1)
        ]
        let placements = [
            CollagePlacement(imageIndex: 0, frame: CGRect(x: 0, y: 0, width: 4, height: 4)),
            CollagePlacement(imageIndex: 1, frame: CGRect(x: 2, y: 2, width: 4, height: 4))
        ]
        let first = try CollageRenderer.render(images: images, placements: placements, background: white)
        let reordered = try CollageRenderer.render(images: images, placements: Array(placements.reversed()), background: white)

        XCTAssertEqual(first.width, 6)
        XCTAssertEqual(first.height, 6)
        XCTAssertEqual(pixel(first, x: 1, y: 1), [255, 0, 0, 255])
        XCTAssertEqual(pixel(first, x: 3, y: 3), [0, 0, 255, 255])
        XCTAssertEqual(pixel(reordered, x: 3, y: 3), [255, 0, 0, 255])
        XCTAssertEqual(pixel(first, x: 5, y: 0), [255, 255, 255, 255])
    }

    func testFreeCollageTranslatesNegativeCoordinatesWithoutClipping() throws {
        let images = [
            image(width: 20, height: 10, red: 1, green: 0, blue: 0),
            image(width: 4, height: 8, red: 0, green: 0, blue: 1)
        ]
        let placements = [
            CollagePlacement(imageIndex: 0, frame: CGRect(x: -10, y: -8, width: 20, height: 10)),
            CollagePlacement(imageIndex: 1, frame: CGRect(x: -2, y: -3, width: 4, height: 8))
        ]
        XCTAssertEqual(try CollageRenderer.bounds(for: placements), CGRect(x: -10, y: -8, width: 20, height: 13))
        let result = try CollageRenderer.render(images: images, placements: placements, background: white)
        XCTAssertEqual(result.width, 20)
        XCTAssertEqual(result.height, 13)
        XCTAssertEqual(pixel(result, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 9, y: 6), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 0, y: 12), [255, 255, 255, 255])
    }

    func testFreeCollageRoundsBoundsOutwardAndResizesSingleImage() throws {
        let source = image(width: 10, height: 20, red: 1, green: 0, blue: 0)
        XCTAssertEqual(
            try CollageRenderer.bounds(for: [CollagePlacement(imageIndex: 0, frame: CGRect(x: -1.5, y: -2.25, width: 2.2, height: 3.1))]),
            CGRect(x: -2, y: -3, width: 3, height: 4)
        )
        for size in [CGSize(width: 5, height: 9), CGSize(width: 1, height: 1)] {
            let result = try CollageRenderer.render(
                images: [source],
                placements: [CollagePlacement(imageIndex: 0, frame: CGRect(origin: CGPoint(x: 45, y: 30), size: size))],
                background: white
            )
            XCTAssertEqual(result.width, Int(size.width))
            XCTAssertEqual(result.height, Int(size.height))
            XCTAssertEqual(pixel(result, x: 0, y: 0), [255, 0, 0, 255])
        }
        XCTAssertEqual(source.width, 10)
        XCTAssertEqual(source.height, 20)
    }

    func testFreeCollagePreservesTopBottomOrientationAndTransparentLayers() throws {
        let bytes = Data([
            255, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 255, 255, 0, 128, 0, 128
        ])
        let foreground = CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        let background = image(width: 2, height: 2, red: 1, green: 0, blue: 0)
        let frame = CGRect(x: -2, y: -4, width: 2, height: 2)
        let result = try CollageRenderer.render(
            images: [background, foreground],
            placements: [CollagePlacement(imageIndex: 0, frame: frame), CollagePlacement(imageIndex: 1, frame: frame)],
            background: white
        )
        XCTAssertEqual(pixel(result, x: 0, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 0), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 0, y: 1), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 1, y: 1), [127, 128, 0, 255])

        let transparentResult = try CollageRenderer.render(
            images: [foreground],
            placements: [CollagePlacement(imageIndex: 0, frame: frame)],
            background: CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        )
        XCTAssertEqual(pixel(transparentResult, x: 1, y: 0), [0, 0, 0, 0])
        XCTAssertEqual(pixel(transparentResult, x: 1, y: 1), [0, 128, 0, 128])
    }

    func testFreeCollageRejectsInvalidFramesAndImageIndices() {
        let source = image(width: 1, height: 1, red: 1, green: 0, blue: 0)
        let frames = [
            CGRect(x: 0, y: 0, width: 0, height: 1),
            CGRect(x: 0, y: 0, width: 1, height: -1),
            CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
            CGRect(x: 0, y: CGFloat.infinity, width: 1, height: 1),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1),
            CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1)
        ]
        for frame in frames {
            XCTAssertThrowsError(try CollageRenderer.bounds(for: [CollagePlacement(imageIndex: 0, frame: frame)])) {
                guard case CollageError.invalidSetting = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        let frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        for indices in [[-1], [1], [0, 0]] {
            XCTAssertThrowsError(try CollageRenderer.render(
                images: [source],
                placements: indices.map { CollagePlacement(imageIndex: $0, frame: frame) },
                background: white
            )) {
                guard case CollageError.invalidSetting = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertThrowsError(try CollageRenderer.bounds(for: [])) {
            guard case CollageError.emptySelection = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    func testFreeCollageRejectsOversizedCanvasAndElementCountBeforeAllocation() {
        for size in [CGSize(width: 32_769, height: 1), CGSize(width: 8_001, height: 8_000)] {
            XCTAssertThrowsError(try CollageRenderer.bounds(for: [CollagePlacement(imageIndex: 0, frame: CGRect(origin: .zero, size: size))])) {
                guard case CollageError.canvasTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        let placements = (0..<4_097).map { CollagePlacement(imageIndex: $0, frame: CGRect(x: 0, y: 0, width: 1, height: 1)) }
        XCTAssertThrowsError(try CollageRenderer.bounds(for: placements)) {
            guard case CollageError.invalidSetting = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertThrowsError(try CollageRenderer.bounds(for: [
            CollagePlacement(imageIndex: 0, frame: CGRect(x: -20_000, y: 0, width: 1, height: 1)),
            CollagePlacement(imageIndex: 1, frame: CGRect(x: 20_000, y: 0, width: 1, height: 1))
        ])) {
            guard case CollageError.canvasTooLarge = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    private var white: CGColor { CGColor(red: 1, green: 1, blue: 1, alpha: 1) }

    private func image(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )!
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = image.dataProvider!.data!
        let bytes = CFDataGetBytePtr(data)!
        let index = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + index, count: 4))
    }
}
