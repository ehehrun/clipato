import AppKit
import XCTest
@testable import Clipato

@MainActor
final class MosaicRendererTests: XCTestCase {
    private func source(width: Int = 96, height: Int = 64, alpha: UInt8 = 255, coloredRows: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = (x + y).isMultiple(of: 2) ? alpha : UInt8(0)
                pixels[offset] = coloredRows ? (y < height / 2 ? value : 0) : value
                pixels[offset + 1] = coloredRows ? 0 : value
                pixels[offset + 2] = coloredRows ? (y >= height / 2 ? value : 0) : value
                pixels[offset + 3] = alpha
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func mosaic(_ shape: MosaicShape, points: [CGPoint], width: CGFloat = 16, size: CGFloat = 8) -> ImageAnnotation {
        ImageAnnotation(tool: .mosaic, points: points, color: .red, width: width, mosaicShape: shape, mosaicSize: size)
    }

    private func pixel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func equal(_ lhs: NSColor, _ rhs: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.redComponent, rhs.redComponent, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(lhs.greenComponent, rhs.greenComponent, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(lhs.blueComponent, rhs.blueComponent, accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(lhs.alphaComponent, rhs.alphaComponent, accuracy: 1 / 255, file: file, line: line)
    }

    func testRectangleAveragesFineDetailsWithoutChangingOutsideOrSource() throws {
        let original = try source()
        let originalBytes = try XCTUnwrap(original.dataProvider?.data) as Data
        let annotation = mosaic(.rectangle, points: [CGPoint(x: 16, y: 8), CGPoint(x: 80, y: 56)])
        let rendered = try renderAnnotatedImage(original, annotations: [annotation])
        let actual = NSBitmapImageRep(cgImage: rendered), before = NSBitmapImageRep(cgImage: original)
        for y in 0..<64 {
            for x in 0..<96 {
                let color = try pixel(actual, x, y)
                if (16..<80).contains(x) && (8..<56).contains(y) {
                    XCTAssertGreaterThan(color.redComponent, 0.30)
                    XCTAssertLessThan(color.redComponent, 0.70)
                    equal(color, try pixel(actual, (x / 8) * 8 + 4, (y / 8) * 8 + 4))
                } else {
                    equal(color, try pixel(before, x, y))
                }
            }
        }
        XCTAssertEqual(try XCTUnwrap(original.dataProvider?.data) as Data, originalBytes)
    }

    func testBrushMasksRoundEndsAndSeparateStrokesWithoutJoiningThem() throws {
        let original = try source()
        let first = mosaic(.brush, points: [CGPoint(x: 16, y: 16), CGPoint(x: 64, y: 16)], width: 12)
        let second = mosaic(.brush, points: [CGPoint(x: 32, y: 48), CGPoint(x: 80, y: 48)], width: 12)
        let actual = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: [first, second]))
        let before = NSBitmapImageRep(cgImage: original)
        for point in [CGPoint(x: 12, y: 16), CGPoint(x: 40, y: 16), CGPoint(x: 68, y: 16), CGPoint(x: 48, y: 48)] {
            let color = try pixel(actual, Int(point.x), Int(point.y))
            XCTAssertGreaterThan(color.redComponent, 0.3)
            XCTAssertLessThan(color.redComponent, 0.7)
        }
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 48, y: 32), CGPoint(x: 90, y: 48)] {
            equal(try pixel(actual, Int(point.x), Int(point.y)), try pixel(before, Int(point.x), Int(point.y)))
        }
    }

    func testStationaryBrushMakesADotAndZeroAreaRectangleDoesNothing() throws {
        let dot = mosaic(.brush, points: [CGPoint(x: 32, y: 24)], width: 16)
        XCTAssertTrue(dot.isDrawable)
        XCTAssertTrue(dot.mosaicMask.contains(CGPoint(x: 32, y: 24)))
        XCTAssertFalse(dot.mosaicMask.contains(CGPoint(x: 40, y: 32)))
        XCTAssertEqual(dot.mosaicMask.boundingBoxOfPath, CGRect(x: 24, y: 16, width: 16, height: 16))
        let original = try source()
        let actual = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: [dot]))
        XCTAssertGreaterThan(try pixel(actual, 32, 24).redComponent, 0.3)
        XCTAssertLessThan(try pixel(actual, 32, 24).redComponent, 0.7)
        equal(try pixel(actual, 40, 32), try pixel(NSBitmapImageRep(cgImage: original), 40, 32))
        let empty = mosaic(.rectangle, points: [CGPoint(x: 8, y: 8), CGPoint(x: 8, y: 32)])
        XCTAssertFalse(empty.isDrawable)
        let untouched = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: [empty]))
        equal(try pixel(untouched, 8, 16), try pixel(NSBitmapImageRep(cgImage: original), 8, 16))
    }

    func testMaskGeometryDoesNotMakeMosaicSelectable() {
        let rectangle = mosaic(.rectangle, points: [CGPoint(x: 40, y: 30), CGPoint(x: 10, y: 10)], width: 80)
        XCTAssertTrue(rectangle.mosaicMask.contains(CGPoint(x: 20, y: 20)))
        XCTAssertFalse(rectangle.mosaicMask.contains(CGPoint(x: 9, y: 20)))
        XCTAssertEqual(rectangle.mosaicMask.boundingBoxOfPath, CGRect(x: 10, y: 10, width: 30, height: 20))
        let brush = mosaic(.brush, points: [CGPoint(x: 20, y: 20), CGPoint(x: 60, y: 20)], width: 12)
        XCTAssertEqual(brush.mosaicMask.boundingBoxOfPath, CGRect(x: 14, y: 14, width: 52, height: 12))
        XCTAssertTrue(brush.mosaicMask.contains(CGPoint(x: 40, y: 20)))
        XCTAssertFalse(brush.mosaicMask.contains(CGPoint(x: 40, y: 30)))
        for annotation in [rectangle, brush] {
            XCTAssertFalse(annotation.hitTest(CGPoint(x: 20, y: 20), tolerance: 40, textBounds: .null))
            XCTAssertTrue(annotation.selectionBounds(textBounds: .null).isNull)
        }
    }

    func testCropLocalPixelsPreserveTopAndBottomOrientation() throws {
        let original = try source(coloredRows: true)
        let crop = CGRect(x: 16, y: 8, width: 64, height: 48)
        let annotation = mosaic(.rectangle, points: [.zero, CGPoint(x: 64, y: 48)])
        let actual = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, crop: crop, annotations: [annotation]))
        XCTAssertEqual(actual.pixelsWide, 64)
        XCTAssertEqual(actual.pixelsHigh, 48)
        let top = try pixel(actual, 20, 8), bottom = try pixel(actual, 20, 40)
        XCTAssertGreaterThan(top.redComponent, 0.3)
        XCTAssertLessThan(top.blueComponent, 0.01)
        XCTAssertGreaterThan(bottom.blueComponent, 0.3)
        XCTAssertLessThan(bottom.redComponent, 0.01)
    }

    func testHalfScalePreviewAndFullResolutionExportUseTheSameBlocks() throws {
        let original = try source(coloredRows: true)
        let annotation = mosaic(.rectangle, points: [CGPoint(x: 16, y: 8), CGPoint(x: 80, y: 56)])
        let exported = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: [annotation]))
        let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(original, in: CGRect(x: 0, y: 0, width: 48, height: 32))
        context.translateBy(x: 0, y: 32)
        context.scaleBy(x: 0.5, y: -0.5)
        try MosaicRenderer(image: original).draw(annotation, in: context)
        let preview = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        for point in [CGPoint(x: 12, y: 8), CGPoint(x: 24, y: 20), CGPoint(x: 36, y: 24)] {
            equal(try pixel(preview, Int(point.x), Int(point.y)), try pixel(exported, Int(point.x) * 2, Int(point.y) * 2))
        }
    }

    func testTranslucentSourceDoesNotShowDetailedPixelsThroughMosaic() throws {
        let original = try source(alpha: 128)
        let annotation = mosaic(.rectangle, points: [CGPoint(x: 16, y: 8), CGPoint(x: 80, y: 56)])
        let actual = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: [annotation]))
        let reference = try pixel(actual, 20, 20)
        XCTAssertEqual(reference.alphaComponent, 128 / 255, accuracy: 1 / 255)
        for y in 17..<23 {
            for x in 17..<23 { equal(try pixel(actual, x, y), reference) }
        }
    }

    func testOverlappingMosaicsUndoAndRedoRestoreRenderedPixels() throws {
        let original = try source()
        let lower = mosaic(.rectangle, points: [CGPoint(x: 8, y: 8), CGPoint(x: 56, y: 48)])
        let upper = mosaic(.brush, points: [CGPoint(x: 48, y: 24), CGPoint(x: 80, y: 24)], width: 24, size: 16)
        var annotations = [lower]
        let addition = AnnotationChange.add(upper)
        addition.apply(to: &annotations)
        let before = try renderAnnotatedImage(original, annotations: annotations)
        addition.undo(in: &annotations)
        let undone = NSBitmapImageRep(cgImage: try renderAnnotatedImage(original, annotations: annotations))
        equal(try pixel(undone, 72, 24), try pixel(NSBitmapImageRep(cgImage: original), 72, 24))
        addition.apply(to: &annotations)
        let restored = try renderAnnotatedImage(original, annotations: annotations)
        XCTAssertEqual(try XCTUnwrap(before.dataProvider?.data) as Data, try XCTUnwrap(restored.dataProvider?.data) as Data)
        addition.undo(in: &annotations)
        XCTAssertEqual(annotations, [lower])
    }
}
