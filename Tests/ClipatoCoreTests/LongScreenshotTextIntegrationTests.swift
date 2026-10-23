import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import XCTest
@testable import ClipatoCore

final class LongScreenshotTextIntegrationTests: XCTestCase {
    func testTextOnLightBackgroundAlignsSmallAndLargeScrollsAfterPNGRoundTrip() throws {
        let mother = try document(width: 759, height: 430)
        let previous = try png(crop(mother, y: 0, height: 206))
        for shift in [13, 54, 121, 196] {
            let next = try png(crop(mother, y: shift, height: 206))
            let analysis = try analyze(previous, next, label: "text 759×206 shift \(shift)")
            guard case .matched(let join) = analysis else {
                XCTFail("Expected text overlap \(206 - shift), got \(analysis)")
                continue
            }
            XCTAssertEqual(join.overlap, 206 - shift)
            let rendered = try LongScreenshot.render(images: [previous, next], joins: [join])
            try assertSamePixels(rendered, crop(mother, y: 0, height: 206 + shift))
        }
    }

    func testSparseTextAndLargeBlankMarginsStillAlignTheSharedText() throws {
        let mother = try document(width: 759, height: 430, sparse: true)
        let previous = try png(crop(mother, y: 0, height: 206))
        let next = try png(crop(mother, y: 87, height: 206))
        let analysis = try analyze(previous, next, label: "sparse text 759×206")
        guard case .matched(let join) = analysis else { return XCTFail("Expected overlap 119, got \(analysis)") }
        XCTAssertEqual(join.overlap, 119)
        try assertSamePixels(LongScreenshot.render(images: [previous, next], joins: [join]), crop(mother, y: 0, height: 293))
    }

    func testMovingScrollbarDoesNotHideTheUnchangedTextOverlap() throws {
        let mother = try document(width: 759, height: 430)
        let previous = try png(scrollbar(crop(mother, y: 0, height: 206), thumbTop: 12))
        let next = try png(scrollbar(crop(mother, y: 54, height: 206), thumbTop: 38))
        let analysis = try analyze(previous, next, label: "text with moving 8 px scrollbar")
        guard case .matched(let join) = analysis else { return XCTFail("Expected overlap 152 despite the scrollbar, got \(analysis)") }
        XCTAssertEqual(join.overlap, 152)
        let rendered = try LongScreenshot.render(images: [previous, next], joins: [join])
        let actualBody = try XCTUnwrap(rendered.cropping(to: CGRect(x: 0, y: 0, width: 747, height: 260)))
        let expectedBody = try XCTUnwrap(mother.cropping(to: CGRect(x: 0, y: 0, width: 747, height: 260)))
        try assertSamePixels(actualBody, expectedBody)
    }

    func testBlankContentWithOnlyScrollbarMovementHasNoAutomaticOffset() throws {
        let background = try context(width: 759, height: 206)
        background.setFillColor(CGColor(gray: 0.97, alpha: 1))
        background.fill(CGRect(x: 0, y: 0, width: 759, height: 206))
        let image = try XCTUnwrap(background.makeImage())
        let previous = try png(scrollbar(image, thumbTop: 12))
        let next = try png(scrollbar(image, thumbTop: 38))
        XCTAssertEqual(try analyze(previous, next, label: "blank with scrollbar"), .noReliableMatch)
    }

    func testRepeatingIdenticalTextRowsDoNotInventAnUnambiguousOffset() throws {
        let mother = try document(width: 759, height: 430, repeating: true)
        let previous = try png(crop(mother, y: 0, height: 206))
        let next = try png(crop(mother, y: 37, height: 206))
        XCTAssertEqual(try analyze(previous, next, label: "repeated text rows"), .noReliableMatch)
    }

    private func document(width: Int, height: Int, sparse: Bool = false, repeating: Bool = false) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        bitmap.setFillColor(CGColor(srgbRed: 0.97, green: 0.975, blue: 0.98, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.textMatrix = .identity
        let lines = sparse ? [
            "A small saved image", "Original pixels remain", "Drag to arrange", "Choose a color tag",
            "Export the final result", "Keep every capture", "Adjust the horizontal position",
            "Shared text defines the overlap", "Review the complete composition"
        ] : [
            "Clipato keeps each screenshot in its original pixel size.",
            "Drag a saved image to the canvas and adjust its position.",
            "自动对齐分析相邻截图的公共内容，原图始终保留。",
            "A green outline marks the selected capture region.",
            "Use the library to filter pictures by their color tag.",
            "窗口底部提供撤销、重做与复制图片操作。",
            "The next picture may overlap only a small part of this page.",
            "Screen content can include short labels and long paragraphs.",
            "继续截图后，可以调整每张图片的位置与接缝。",
            "Save the completed composition as a PNG image.",
            "A moving scrollbar should not decide the content alignment.",
            "The original files remain available while editing.",
            "不同语言的文字与浅色背景也是常见的截图内容。",
            "The image underneath remains complete when a later picture covers its corner.",
            "重新检测后，共同文字的位置决定两张截图之间的位移。",
            "A short overlap may contain only the lower edge of one unique sentence.",
            "Check the entire canvas before saving this final portion of the document."
        ]
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, sparse ? 13 : 16, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1)
        ]
        let spacing = sparse ? 52 : 25
        for (index, top) in stride(from: 6, to: height, by: spacing).enumerated() {
            let text = repeating ? "The same row appears again. 重复的相同文字。" : "\(index + 1). \(lines[index])"
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            bitmap.textPosition = CGPoint(x: 24, y: height - top - 17)
            CTLineDraw(line, bitmap)
        }
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func scrollbar(_ image: CGImage, thumbTop: Int) throws -> CGImage {
        let bitmap = try context(width: image.width, height: image.height)
        bitmap.setBlendMode(.copy)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        bitmap.setFillColor(CGColor(gray: 0.94, alpha: 1))
        bitmap.fill(CGRect(x: image.width - 10, y: 0, width: 10, height: image.height))
        bitmap.setFillColor(CGColor(gray: 0.55, alpha: 1))
        bitmap.fill(CGRect(x: image.width - 9, y: image.height - thumbTop - 46, width: 8, height: 46))
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func analyze(_ previous: CGImage, _ next: CGImage, label: String) throws -> LongScreenshotAnalysis {
        let started = ProcessInfo.processInfo.systemUptime
        let cpuStarted = clock()
        let result = try LongScreenshot.analyze(previous: previous, next: next)
        print(String(format: "%@: wall %.4fs, CPU %.4fs", label,
                     ProcessInfo.processInfo.systemUptime - started, Double(clock() - cpuStarted) / Double(CLOCKS_PER_SEC)))
        return result
    }

    private func crop(_ image: CGImage, y: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)))
    }

    private func png(_ image: CGImage) throws -> CGImage {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }

    private func assertSamePixels(_ actual: CGImage, _ expected: CGImage, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(actual.width, expected.width, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, file: file, line: line)
        guard actual.width == expected.width, actual.height == expected.height else { return }
        let a = try context(width: actual.width, height: actual.height)
        let b = try context(width: expected.width, height: expected.height)
        let bounds = CGRect(x: 0, y: 0, width: actual.width, height: actual.height)
        a.draw(actual, in: bounds)
        b.draw(expected, in: bounds)
        XCTAssertEqual(memcmp(a.data!, b.data!, actual.width * actual.height * 4), 0, "The rendered content must reproduce the source pixels", file: file, line: line)
    }
}
