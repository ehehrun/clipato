import CoreGraphics
import CoreText
import Foundation
import ImageIO
import XCTest
@testable import ClipatoCore

final class LongScreenshotRegistrationTests: XCTestCase {
    func testDefaultAlignmentReconstructsTextWithOnlyFiveSharedPixelRows() throws {
        let width = 725
        let height = 253
        let bitmap = try context(width: width, height: height)
        bitmap.setFillColor(CGColor(srgbRed: 0.97, green: 0.965, blue: 0.92, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setFillColor(CGColor(srgbRed: 0.92, green: 0.91, blue: 0.85, alpha: 1))
        bitmap.addPath(CGPath(roundedRect: CGRect(x: 445, y: 18, width: 280, height: 48),
                              cornerWidth: 14, cornerHeight: 14, transform: nil))
        bitmap.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("PingFangSC-Regular" as CFString, 17, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
        ]
        let lines: [(text: String, x: Int, baseline: Int)] = [
            ("1. 保留第一张截图的完整内容。", 16, 26),
            ("2. 根据共同文字的位置拼合上下两张图片。", 16, 58),
            ("3. 接缝可以位于字形内部，无需保留整行文字。", 16, 90),
            ("只有五行像素重复时，也应恢复完整句子与其原始位置。", 16, 130),
            ("下方的新消息应当完整保留", 460, 216)
        ]
        for item in lines {
            bitmap.textPosition = CGPoint(x: item.x, y: height - item.baseline)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes)), bitmap)
        }
        let mother = try XCTUnwrap(bitmap.makeImage())
        let seam = try rgba(crop(mother, CGRect(x: 0, y: 124, width: width, height: 5)))
        XCTAssertGreaterThan(stride(from: 0, to: seam.count, by: 4).filter { seam[$0] < 100 }.count, 100,
                             "The narrow overlap must cross actual text strokes rather than a blank margin")
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: width, height: 129),
                               second: CGRect(x: 0, y: 124, width: width, height: 129))
    }

    func testHighResolutionRepeatedGlyphDocumentRegistersAndPreservesAllPixels() throws {
        let mother = try document(width: 2560, height: 2300)
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                               second: CGRect(x: 0, y: 560, width: 2560, height: 1440))
    }

    func testTextCropsWithHorizontalDriftAlignAndPreserveOverhangingPixels() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: 620, height: 250),
                               second: CGRect(x: 29, y: 105, width: 620, height: 250))
    }

    func testHorizontalDriftWithOnlyOneSharedTextLineStillRegisters() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: 620, height: 250),
                               second: CGRect(x: 29, y: 219, width: 620, height: 250))
    }

    func testDifferentCropDimensionsAlignOnTheSameDocumentContent() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 40, y: 0, width: 620, height: 260),
                               second: CGRect(x: 0, y: 92, width: 700, height: 220))
    }

    func testCaptureMovingUpAndLeftProducesAnOverlapBeyondTheFirstImageHeight() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 30, y: 105, width: 620, height: 250),
                               second: CGRect(x: 0, y: 0, width: 620, height: 250))
    }

    func testHorizontalCapturesProduceOneContinuousWideDocument() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: 470, height: 320),
                               second: CGRect(x: 190, y: 0, width: 470, height: 320))
    }

    func testSmallAntialiasingDifferencesDoNotPreventMatchingTheTextEdges() throws {
        let mother = try document(width: 900, height: 600)
        let firstRect = CGRect(x: 0, y: 0, width: 620, height: 250)
        let secondRect = CGRect(x: 23, y: 87, width: 620, height: 250)
        let first = try png(crop(mother, firstRect))
        let second = try png(changingTextAntialiasing(crop(mother, secondRect)))
        try assertRegistration(images: [first, second], rectangles: [firstRect, secondRect])
    }

    func testAContainedCropCanAlignWithoutExpandingTheCompleteImage() throws {
        let mother = try document(width: 900, height: 600)
        try assertRegistration(mother, first: CGRect(x: 0, y: 0, width: 700, height: 390),
                               second: CGRect(x: 91, y: 73, width: 430, height: 210))
    }

    func testDisjointTextContentDoesNotAcquireAnInventedTranslation() throws {
        let mother = try document(width: 900, height: 600)
        let first = try png(crop(mother, CGRect(x: 0, y: 0, width: 620, height: 220)))
        let second = try png(crop(mother, CGRect(x: 29, y: 310, width: 620, height: 220)))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .noReliableMatch)
    }

    func testFlatBackgroundsOfDifferentSizesDoNotProvideRegistrationEvidence() throws {
        let first = try png(blank(width: 620, height: 250))
        let second = try png(blank(width: 530, height: 220))
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .noReliableMatch)
    }

    func testRepeatedParagraphBlocksWithValidForwardAndBackwardOffsetsRemainAmbiguous() throws {
        let block = try document(width: 620, height: 124)
        let bitmap = try context(width: 620, height: 496)
        bitmap.setBlendMode(.copy)
        for index in 0..<4 {
            bitmap.draw(block, in: CGRect(x: 0, y: index * 124, width: 620, height: 124))
        }
        let mother = try XCTUnwrap(bitmap.makeImage())
        let first = try png(crop(mother, CGRect(x: 0, y: 0, width: 620, height: 240)))
        let second = try png(crop(mother, CGRect(x: 0, y: 73, width: 620, height: 240)))
        // Both +73 and -51 place the same four-line paragraph block over equal pixels.
        for dy in [73, -51] {
            let a = try rgba(crop(first, CGRect(x: 0, y: max(0, dy), width: 620, height: 240 - abs(dy))))
            let b = try rgba(crop(second, CGRect(x: 0, y: max(0, -dy), width: 620, height: 240 - abs(dy))))
            XCTAssertTrue(a.elementsEqual(b), "The ambiguity fixture must have identical shared pixels in both directions")
        }
        XCTAssertEqual(try LongScreenshot.analyze(previous: first, next: second), .noReliableMatch)
    }

    private func assertRegistration(_ mother: CGImage, first: CGRect, second: CGRect,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let images = try [first, second].map { try png(crop(mother, $0)) }
        try assertRegistration(images: images, rectangles: [first, second], file: file, line: line)
    }

    private func assertRegistration(images: [CGImage], rectangles: [CGRect],
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let analysis = try LongScreenshot.analyze(previous: images[0], next: images[1])
        guard case .matched(let join) = analysis else {
            return XCTFail("The shared document should register, received \(analysis)", file: file, line: line)
        }
        let dx = Int(rectangles[1].minX - rectangles[0].minX)
        let dy = Int(rectangles[1].minY - rectangles[0].minY)
        XCTAssertEqual(join.offsetX, dx, file: file, line: line)
        XCTAssertEqual(join.overlap, images[0].height - dy, file: file, line: line)
        let bounds = rectangles[0].union(rectangles[1])
        let layout = try LongScreenshot.layout(images: images, joins: [join])
        XCTAssertEqual(layout.size, bounds.size, file: file, line: line)
        for index in images.indices {
            XCTAssertEqual(layout.placements[index].frame,
                           rectangles[index].offsetBy(dx: -bounds.minX, dy: -bounds.minY), file: file, line: line)
        }
        let rendered = try LongScreenshot.render(images: images, joins: [join])
        let actual = try rgba(rendered)
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard rendered.width == width, rendered.height == height else {
            return XCTFail("The rendered canvas must contain both original crop extents", file: file, line: line)
        }
        // The independent crop coordinates determine coverage and the later image owns an overlap.
        var expected = [UInt8](repeating: 255, count: width * height * 4)
        for index in images.indices {
            let source = try rgba(images[index])
            let x = Int(rectangles[index].minX - bounds.minX)
            let y = Int(rectangles[index].minY - bounds.minY)
            for row in 0..<images[index].height {
                let sourceStart = row * images[index].width * 4
                let destinationStart = ((y + row) * width + x) * 4
                expected.replaceSubrange(destinationStart..<(destinationStart + images[index].width * 4),
                                         with: source[sourceStart..<(sourceStart + images[index].width * 4)])
            }
        }
        if let index = actual.indices.first(where: { actual[$0] != expected[$0] }) {
            XCTFail("Incorrect composited pixel at (\(index / 4 % width), \(index / 4 / width)), channel \(index % 4)", file: file, line: line)
        }
        print(String(format: "Text registration (%d, %d): %.4fs including render verification", dx, dy,
                     ProcessInfo.processInfo.systemUptime - started))
    }

    private func document(width: Int, height: Int) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        bitmap.setFillColor(CGColor(srgbRed: 0.97, green: 0.965, blue: 0.92, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.textMatrix = .identity
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 17, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)
        ]
        let sentences = [
            "Clipato keeps the original pixels while placing pictures on a common canvas.",
            "自动对齐通过相同文字与图形的位置确定相邻截图之间的偏移。",
            "A second picture may move left, right, up, or down without losing its edge.",
            "图片之间可以交叉覆盖，用户也可以继续拖动调整每一张截图。",
            "Small changes to text antialiasing should preserve the same underlying content.",
            "The export retains the entire image even when its width differs from its neighbor.",
            "最后的拼图画布需要包含所有原始图片，而不只包含匹配出来的部分。",
            "Use common words and distinct symbols to identify the real shared document.",
            "Clear the selection to inspect the completed composition without an outline.",
            "保存后的图片和屏幕选区保持原始像素尺寸，空白不代表可靠的匹配。",
            "Rendering must preserve the later picture where two image rectangles overlap.",
            "Each paragraph here represents another portion of a longer captured page.",
            "移动鼠标来调整图片的位置，或者使用方向键进行精确的一像素微调。",
            "Independent crops provide a known translation for testing the image matcher.",
            "Previous and next are capture order, so the document may also move backwards.",
            "Different text, a new sentence, and a unique paragraph prevent false matches."
        ]
        for (index, top) in stride(from: 8, to: height, by: 31).enumerated() {
            let text = "\(index + 1). " + sentences[index % sentences.count]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            bitmap.textPosition = CGPoint(x: 24, y: height - top - 19)
            CTLineDraw(line, bitmap)
        }
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func changingTextAntialiasing(_ image: CGImage) throws -> CGImage {
        var bytes = try rgba(image)
        var changed = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where (40...220).contains(Int(bytes[index])) {
            for channel in 0..<3 { bytes[index + channel] += 4 }
            changed += 1
        }
        XCTAssertGreaterThan(changed, 500, "The fixture must change text edge pixels, not just blank margins")
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func blank(width: Int, height: Int) throws -> CGImage {
        let bitmap = try context(width: width, height: height)
        bitmap.setFillColor(CGColor(srgbRed: 0.97, green: 0.965, blue: 0.92, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(bitmap.makeImage())
    }

    private func crop(_ image: CGImage, _ rectangle: CGRect) throws -> CGImage {
        try XCTUnwrap(image.cropping(to: rectangle))
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

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let bitmap = try context(width: image.width, height: image.height)
        bitmap.setBlendMode(.copy)
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: bitmap.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
}
