import CoreGraphics
import Foundation
import XCTest
@testable import Clipato

final class ScreenshotColorPickerTests: XCTestCase {
    func testColorFormatDefaultsAndPersistsInUserDefaults() throws {
        let name = "ClipatoScreenshotColorPickerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(ScreenshotColorFormat.saved(in: defaults), .hex)
        for format in ScreenshotColorFormat.allCases {
            defaults.set(format.rawValue, forKey: ScreenshotColorFormat.defaultsKey)
            XCTAssertEqual(ScreenshotColorFormat.saved(in: try XCTUnwrap(UserDefaults(suiteName: name))), format)
        }
        defaults.set("unsupported", forKey: ScreenshotColorFormat.defaultsKey)
        XCTAssertEqual(ScreenshotColorFormat.saved(in: defaults), .hex)
    }

    func testFormatCycleAndTitles() {
        XCTAssertEqual(ScreenshotColorFormat.hex.title, "HEX")
        XCTAssertEqual(ScreenshotColorFormat.rgb.title, "RGB")
        XCTAssertEqual(ScreenshotColorFormat.hsl.title, "HSL")
        XCTAssertEqual(ScreenshotColorFormat.hex.next, .rgb)
        XCTAssertEqual(ScreenshotColorFormat.rgb.next, .hsl)
        XCTAssertEqual(ScreenshotColorFormat.hsl.next, .hex)
    }

    func testHexAndRGBUseExactEightBitChannels() {
        let color = ScreenPixelColor(r: 0, g: 15, b: 255)
        XCTAssertEqual(color.formatted(.hex), "#000FFF")
        XCTAssertEqual(color.formatted(.rgb), "rgb(0, 15, 255)")
    }

    func testHSLHandlesPrimariesSecondariesAndAchromaticColors() {
        let cases: [(ScreenPixelColor, String)] = [
            (.init(r: 255, g: 0, b: 0), "hsl(0, 100%, 50%)"),
            (.init(r: 255, g: 255, b: 0), "hsl(60, 100%, 50%)"),
            (.init(r: 0, g: 255, b: 0), "hsl(120, 100%, 50%)"),
            (.init(r: 0, g: 255, b: 255), "hsl(180, 100%, 50%)"),
            (.init(r: 0, g: 0, b: 255), "hsl(240, 100%, 50%)"),
            (.init(r: 255, g: 0, b: 255), "hsl(300, 100%, 50%)"),
            (.init(r: 0, g: 0, b: 0), "hsl(0, 0%, 0%)"),
            (.init(r: 255, g: 255, b: 255), "hsl(0, 0%, 100%)"),
            (.init(r: 128, g: 128, b: 128), "hsl(0, 0%, 50.2%)"),
            (.init(r: 250, g: 30, b: 90), "hsl(343.6, 95.7%, 54.9%)")
        ]
        for (color, expected) in cases { XCTAssertEqual(color.formatted(.hsl), expected) }
    }

    func testSamplesOriginalTopLeftCoordinatesAndAllCorners() throws {
        let sampler = try ScreenPixelColorSampler()
        let image = try image(width: 3, height: 2, bytes: [
            255, 0, 0, 255,   0, 255, 0, 255,   0, 0, 255, 255,
            255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255
        ])
        let expected: [[ScreenPixelColor]] = [
            [.init(r: 255, g: 0, b: 0), .init(r: 0, g: 255, b: 0), .init(r: 0, g: 0, b: 255)],
            [.init(r: 255, g: 255, b: 0), .init(r: 255, g: 0, b: 255), .init(r: 0, g: 255, b: 255)]
        ]
        for y in 0..<2 {
            for x in 0..<3 { XCTAssertEqual(try sampler.sample(image: image, x: x, y: y), expected[y][x]) }
        }
        XCTAssertEqual(try sampler.sample(image: image, x: 0, y: 0), expected[0][0])
    }

    func testConvertsDisplayP3ToSRGBRatherThanReportingSourceBytes() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let original = try XCTUnwrap(CGColor(colorSpace: p3, components: [180.0 / 255, 100.0 / 255, 80.0 / 255, 1]))
        let converted = try XCTUnwrap(original.converted(to: srgb, intent: .defaultIntent, options: nil))
        let components = try XCTUnwrap(converted.components)
        let sample = try ScreenPixelColor.sample(image: image(width: 1, height: 1, bytes: [180, 100, 80, 255], colorSpace: p3), x: 0, y: 0)
        XCTAssertEqual(Double(sample.r), Double(components[0]) * 255, accuracy: 1)
        XCTAssertEqual(Double(sample.g), Double(components[1]) * 255, accuracy: 1)
        XCTAssertEqual(Double(sample.b), Double(components[2]) * 255, accuracy: 1)
        XCTAssertNotEqual(sample, ScreenPixelColor(r: 180, g: 100, b: 80))
    }

    func testUnpremultipliesAlphaAndHandlesFullyTransparentPixels() throws {
        let translucent = try image(width: 1, height: 1, bytes: [128, 64, 32, 128])
        XCTAssertEqual(try ScreenPixelColor.sample(image: translucent, x: 0, y: 0), .init(r: 255, g: 128, b: 64))
        let transparent = try image(width: 1, height: 1, bytes: [0, 0, 0, 0])
        XCTAssertEqual(try ScreenPixelColor.sample(image: transparent, x: 0, y: 0), .init(r: 0, g: 0, b: 0))
    }

    func testReadsBGRABitmapsWithoutAssumingSourceByteOrder() throws {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        let image = try image(width: 1, height: 1, bytes: [64, 128, 255, 255], bitmapInfo: bitmapInfo)
        XCTAssertEqual(try ScreenPixelColor.sample(image: image, x: 0, y: 0), .init(r: 255, g: 128, b: 64))
    }

    func testReusableSamplerDoesNotRetainColorOrConversionStateBetweenImages() throws {
        let sampler = try ScreenPixelColorSampler()
        let opaque = try image(width: 1, height: 1, bytes: [255, 0, 0, 255])
        let transparent = try image(width: 1, height: 1, bytes: [0, 0, 0, 0])
        let translucent = try image(width: 1, height: 1, bytes: [128, 64, 32, 128])
        let bgra = try image(width: 1, height: 1, bytes: [64, 128, 255, 255],
                             bitmapInfo: .byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)))
        let p3 = try image(width: 1, height: 1, bytes: [180, 100, 80, 255],
                           colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)))
        let p3Color = try XCTUnwrap(CGColor(colorSpace: XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
                                          components: [180.0 / 255, 100.0 / 255, 80.0 / 255, 1]))
        let converted = try XCTUnwrap(p3Color.converted(to: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                                      intent: .defaultIntent, options: nil)?.components)

        for _ in 0..<4 {
            XCTAssertEqual(try sampler.sample(image: opaque, x: 0, y: 0), .init(r: 255, g: 0, b: 0))
            XCTAssertEqual(try sampler.sample(image: transparent, x: 0, y: 0), .init(r: 0, g: 0, b: 0))
            XCTAssertEqual(try sampler.sample(image: translucent, x: 0, y: 0), .init(r: 255, g: 128, b: 64))
            XCTAssertEqual(try sampler.sample(image: bgra, x: 0, y: 0), .init(r: 255, g: 128, b: 64))
            let color = try sampler.sample(image: p3, x: 0, y: 0)
            XCTAssertEqual(Double(color.r), Double(converted[0]) * 255, accuracy: 1)
            XCTAssertEqual(Double(color.g), Double(converted[1]) * 255, accuracy: 1)
            XCTAssertEqual(Double(color.b), Double(converted[2]) * 255, accuracy: 1)
            XCTAssertThrowsError(try sampler.sample(image: p3, x: 1, y: 0)) {
                XCTAssertEqual($0 as? ScreenPixelColorError, .outsideImage)
            }
            XCTAssertEqual(try sampler.sample(image: opaque, x: 0, y: 0), .init(r: 255, g: 0, b: 0))
        }
    }

    func testReusableSamplerHonorsProviderRowPaddingAndNonSequentialCoordinates() throws {
        let bytes: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 91, 92, 93, 94,
            0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 0, 255, 95, 96, 97, 98
        ]
        let image = try XCTUnwrap(CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 16, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                         bitmapInfo: .byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
                                         provider: XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)),
                                         decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let sampler = try ScreenPixelColorSampler()
        for (x, y, color) in [(2, 1, ScreenPixelColor(r: 255, g: 255, b: 0)),
                              (0, 0, .init(r: 255, g: 0, b: 0)), (1, 1, .init(r: 255, g: 0, b: 255)),
                              (2, 0, .init(r: 0, g: 0, b: 255)), (0, 1, .init(r: 0, g: 255, b: 255))] {
            XCTAssertEqual(try sampler.sample(image: image, x: x, y: y), color)
        }
    }

    func testRejectsCoordinatesOutsideImageInsteadOfInventingAColor() throws {
        let image = try image(width: 1, height: 1, bytes: [255, 0, 0, 255])
        for (x, y) in [(-1, 0), (0, -1), (1, 0), (0, 1), (Int.max, Int.max)] {
            XCTAssertThrowsError(try ScreenPixelColor.sample(image: image, x: x, y: y)) {
                XCTAssertEqual($0 as? ScreenPixelColorError, .outsideImage)
            }
        }
    }

    private func image(width: Int, height: Int, bytes: [UInt8],
                       colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
}
