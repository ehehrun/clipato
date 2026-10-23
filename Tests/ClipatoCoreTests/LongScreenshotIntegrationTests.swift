import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ClipatoCore

final class LongScreenshotIntegrationTests: XCTestCase {
    func test1920By1080PNGFramesWithExactlyTenPixelOverlapReconstructMotherPixelForPixel() throws {
        let directory = try temporaryDirectory()
        let mother = try pngRoundTrip(texture(width: 1920, height: 2150), at: directory.appendingPathComponent("mother.png"))
        let top = try pngRoundTrip(crop(mother, y: 0, height: 1080), at: directory.appendingPathComponent("top.png"))
        let bottom = try pngRoundTrip(crop(mother, y: 1070, height: 1080), at: directory.appendingPathComponent("bottom.png"))
        let start = Date()
        let analysis = try LongScreenshot.analyze(previous: top, next: bottom, minimumOverlap: 10)
        let analyzed = Date().timeIntervalSince(start)
        guard case .matched(let join) = analysis else { return XCTFail("Expected the real ten-row overlap, got \(analysis)") }
        XCTAssertEqual(join.overlap, 10)
        let renderStart = Date()
        let result = try LongScreenshot.render(images: [top, bottom], joins: [join])
        let rendered = Date().timeIntervalSince(renderStart)
        let output = try pngRoundTrip(result, at: directory.appendingPathComponent("output.png"))
        try assertSamePixels(output, mother)
        print(String(format: "1920×1080 PNG pair: analyze %.3fs, render %.3fs", analyzed, rendered))
    }

    func testThreePNGCropsWithDifferentOverlapsReconstructIndependentMother() throws {
        let directory = try temporaryDirectory()
        let mother = try pngRoundTrip(texture(width: 384, height: 484), at: directory.appendingPathComponent("mother.png"))
        let starts = [0, 203, 244]
        let frames = try starts.enumerated().map { index, y in
            try pngRoundTrip(crop(mother, y: y, height: 240), at: directory.appendingPathComponent("frame-\(index).png"))
        }
        var joins: [LongScreenshotJoin] = []
        for index in 1..<frames.count {
            let analysis = try LongScreenshot.analyze(previous: frames[index - 1], next: frames[index])
            guard case .matched(let join) = analysis else { return XCTFail("Expected a real crop overlap, got \(analysis)") }
            joins.append(join)
        }
        XCTAssertEqual(joins.map(\.overlap), [37, 199])
        let result = try LongScreenshot.render(images: frames, joins: joins)
        try assertSamePixels(result, mother)
    }

    func testRepeatedPNGIsDetectedWithoutInventingAScrollOffset() throws {
        let directory = try temporaryDirectory()
        let original = try texture(width: 640, height: 360)
        let first = try pngRoundTrip(original, at: directory.appendingPathComponent("first.png"))
        let second = try pngRoundTrip(original, at: directory.appendingPathComponent("second.png"))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .duplicate)
    }

    func testAdjacentNonoverlappingPNGFramesDoNotReceiveAnAutomaticJoin() throws {
        let directory = try temporaryDirectory()
        let mother = try texture(width: 320, height: 400)
        let first = try pngRoundTrip(crop(mother, y: 0, height: 200), at: directory.appendingPathComponent("first.png"))
        let second = try pngRoundTrip(crop(mother, y: 200, height: 200), at: directory.appendingPathComponent("second.png"))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .noReliableMatch)
    }

    func testPeriodicRowsWithSeveralEquallyValidAlignmentsAreNotAutomaticallyJoined() throws {
        let directory = try temporaryDirectory()
        let mother = try texture(width: 256, height: 180, verticalPeriod: 30)
        let first = try pngRoundTrip(crop(mother, y: 0, height: 120), at: directory.appendingPathComponent("first.png"))
        let second = try pngRoundTrip(crop(mother, y: 40, height: 120), at: directory.appendingPathComponent("second.png"))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .noReliableMatch)
    }

    private func texture(width: Int, height: Int, verticalPeriod: Int? = nil) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let row = UInt32(verticalPeriod.map { y % $0 } ?? y)
            for x in 0..<width {
                var value = UInt32(x) &* 0x9e3779b1 &+ row &* 0x85ebca6b
                value ^= value >> 16
                value &*= 0x7feb352d
                value ^= value >> 15
                let pixel = (y * width + x) * 4
                bytes[pixel] = UInt8(truncatingIfNeeded: value)
                bytes[pixel + 1] = UInt8(truncatingIfNeeded: value >> 8)
                bytes[pixel + 2] = UInt8(truncatingIfNeeded: value >> 16)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)))
    }

    private func pngRoundTrip(_ image: CGImage, at url: URL) throws -> CGImage {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private func assertSamePixels(_ actual: CGImage, _ expected: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        let actualBytes = try rgba(actual)
        let expectedBytes = try rgba(expected)
        if let index = actualBytes.indices.first(where: { actualBytes[$0] != expectedBytes[$0] }) {
            let pixel = index / 4
            XCTFail("Pixel mismatch at x=\(pixel % actual.width), y=\(pixel / actual.width), channel=\(index % 4): \(actualBytes[index]) vs \(expectedBytes[index])", file: file, line: line)
        }
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-LongScreenshotIntegration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}
