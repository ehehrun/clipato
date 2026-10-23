import AppKit
import XCTest
@testable import Clipato

@MainActor
final class ImageAnnotationTests: XCTestCase {
    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 10, width: 80, height: 30))
        return try XCTUnwrap(context.makeImage())
    }

    func testCropPreservesSourceOrientationAndOwnsOnlySelectedPixels() async throws {
        let image = try fixture()
        let crop = CGRect(x: 20, y: 80, width: 80, height: 60)
        let result = try renderAnnotatedImage(image, crop: crop, annotations: [])
        XCTAssertEqual(result.width, 80)
        XCTAssertEqual(result.height, 60)
        XCTAssertLessThan(CFDataGetLength(try XCTUnwrap(result.dataProvider?.data)), CFDataGetLength(try XCTUnwrap(image.dataProvider?.data)))
        let original = NSBitmapImageRep(cgImage: image), actual = NSBitmapImageRep(cgImage: result)
        for point in [CGPoint(x: 20, y: 5), CGPoint(x: 20, y: 50)] {
            let expected = try XCTUnwrap(original.colorAt(x: Int(point.x + crop.minX), y: Int(point.y + crop.minY))?.usingColorSpace(.sRGB))
            let pixel = try XCTUnwrap(actual.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
            XCTAssertEqual(pixel.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(pixel.greenComponent, expected.greenComponent, accuracy: 0.01)
            XCTAssertEqual(pixel.blueComponent, expected.blueComponent, accuracy: 0.01)
        }
    }

    func testAnnotationUsesCropLocalPixelsAndSelectedColor() async throws {
        let image = try fixture()
        let annotation = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], color: .green, width: 4)
        let result = try renderAnnotatedImage(image, crop: CGRect(x: 100, y: 50, width: 80, height: 60), annotations: [annotation])
        let actual = NSBitmapImageRep(cgImage: result)
        let edge = try XCTUnwrap(actual.colorAt(x: 10, y: 20)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(edge.greenComponent, 0.95)
        XCTAssertLessThan(edge.redComponent, 0.05)
        let inside = try XCTUnwrap(actual.colorAt(x: 20, y: 20)?.usingColorSpace(.sRGB))
        let original = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 120, y: 70)?.usingColorSpace(.sRGB))
        XCTAssertEqual(inside.blueComponent, original.blueComponent, accuracy: 0.01)
    }

    func testMultilineTextRendersUprightInCropLocalPixels() async throws {
        _ = NSApplication.shared
        let annotation = ImageAnnotation(tool: .text, points: [CGPoint(x: 8, y: 7)], color: .red, width: 0,
                                         text: "F\n中文", fontSize: 28, textWidth: 110)
        let original = try fixture()
        let result = try renderAnnotatedImage(original, crop: CGRect(x: 100, y: 50, width: 130, height: 100), annotations: [annotation])
        XCTAssertEqual(result.width, 130)
        XCTAssertEqual(result.height, 100)
        let bitmap = NSBitmapImageRep(cgImage: result)
        var rows = [Int: [Int]]()
        for y in 0..<result.height {
            for x in 0..<result.width {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2 {
                    rows[y, default: []].append(x)
                }
            }
        }
        let occupied = rows.keys.sorted()
        let first = try XCTUnwrap(occupied.first)
        XCTAssertGreaterThanOrEqual(first, 7)
        XCTAssertLessThan(first, 20)
        XCTAssertGreaterThan(rows.values.reduce(0) { $0 + $1.count }, 250)
        XCTAssertTrue(rows.values.joined().allSatisfy { (8..<118).contains($0) })
        let gap = try XCTUnwrap(zip(occupied, occupied.dropFirst()).first { $1 - $0 > 3 })
        let top = (first...gap.0).compactMap { rows[$0]?.count }
        XCTAssertGreaterThan(top.prefix(4).max()!, top.suffix(4).max()! * 2, "The F top bar must remain above its vertical stem")
        XCTAssertGreaterThan(occupied.last!, gap.1 + 15, "The Chinese second line must be present below the Latin first line")
        XCTAssertLessThan(occupied.last!, 85)
        let untouched = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        let source = try XCTUnwrap(NSBitmapImageRep(cgImage: original).colorAt(x: 100, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertEqual(untouched.blueComponent, source.blueComponent, accuracy: 0.02)
    }

    func testInvalidCropIsRejectedRatherThanSilentlyClipped() async throws {
        let image = try fixture()
        for crop in [CGRect.zero, CGRect(x: -2, y: 0, width: 20, height: 20), CGRect(x: 230, y: 150, width: 20, height: 20)] {
            XCTAssertThrowsError(try renderAnnotatedImage(image, crop: crop, annotations: []))
        }
    }
}
