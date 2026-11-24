import AppKit
import XCTest
@testable import Clipato

@MainActor
final class PinnedImageSizingTests: XCTestCase {
    private let visibleFrame = CGRect(x: -1600, y: 100, width: 1600, height: 1000)

    func testOriginalPointSizeIsIndependentOfCapturedPixelDensity() {
        let pointSize = CGSize(width: 600, height: 400)
        for imageSize in [pointSize, CGSize(width: 1200, height: 800)] {
            let frame = ScreenshotController.pinnedImageFrame(imageSize: imageSize, frame: nil,
                pointSize: pointSize, visibleFrame: visibleFrame)
            XCTAssertEqual(frame, CGRect(origin: .zero, size: pointSize))
        }
    }

    func testKnownScreenshotSizeIsNotReducedByTheGenericImageLimit() {
        let pointSize = CGSize(width: 1100.5, height: 800.5)
        let frame = ScreenshotController.pinnedImageFrame(imageSize: CGSize(width: 2201, height: 1601), frame: nil,
            pointSize: pointSize, visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(frame, CGRect(origin: .zero, size: pointSize))
    }

    func testExplicitCaptureFrameKeepsItsPositionAndTakesPriorityOverStoredSize() {
        let original = CGRect(x: -1200.5, y: 100.5, width: 930.5, height: 520.5)
        let frame = ScreenshotController.pinnedImageFrame(imageSize: CGSize(width: 1861, height: 1041), frame: original,
            pointSize: CGSize(width: 300, height: 200), origin: CGPoint(x: 100, y: 200), visibleFrame: visibleFrame)
        XCTAssertEqual(frame, original)
    }

    func testRestoredPositionUsesScreenPointsWithoutResizingTheSelection() {
        let origin = CGPoint(x: -1200.5, y: 350.5)
        let size = CGSize(width: 800.5, height: 400.5)
        let frame = ScreenshotController.pinnedImageFrame(imageSize: CGSize(width: 1601, height: 801), frame: nil,
            pointSize: size, origin: origin, visibleFrame: visibleFrame)
        XCTAssertEqual(frame, CGRect(origin: origin, size: size))
        XCTAssertEqual(ScreenshotController.visiblePinnedImageFrame(frame, on: [
            CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame,
        ]), frame)
    }

    func testOrdinaryImageKeepsItsPositionAndUsesTheExistingSizeLimit() {
        let origin = CGPoint(x: -1000.5, y: 200.5)
        let frame = ScreenshotController.pinnedImageFrame(imageSize: CGSize(width: 2000, height: 1000), frame: nil,
            pointSize: nil, origin: origin, visibleFrame: visibleFrame)
        XCTAssertEqual(frame, CGRect(origin: origin, size: CGSize(width: 640, height: 320)))
    }

    func testDisconnectedDisplayMovesImageToNearestRemainingScreenWithoutChangingSize() {
        let frame = CGRect(x: -2200.5, y: 1500.5, width: 800.5, height: 400.5)
        let restored = ScreenshotController.visiblePinnedImageFrame(frame, on: [
            CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame,
        ])
        XCTAssertEqual(restored, CGRect(x: -1600, y: 699.5, width: 800.5, height: 400.5))
    }

    func testOversizedImageIsRepositionedWithoutReducingItsOriginalSize() {
        let frame = CGRect(x: 3000, y: 3000, width: 2000.5, height: 1200.5)
        let restored = ScreenshotController.visiblePinnedImageFrame(frame, on: [visibleFrame])
        XCTAssertEqual(restored, CGRect(x: -1600, y: 100, width: 2000.5, height: 1200.5))
    }

    func testPartlyVisibleImageKeepsItsUserChosenPosition() {
        let frame = CGRect(x: -1700.5, y: 500.5, width: 300, height: 200)
        XCTAssertEqual(ScreenshotController.visiblePinnedImageFrame(frame, on: [visibleFrame]), frame)
    }

    func testOrdinaryImagesStillFitTheWidthAndHeightLimitsWithoutUpscaling() {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 1600, height: 1000), CGSize(width: 640, height: 400)),
            (CGSize(width: 300, height: 3000), CGSize(width: 75, height: 750)),
            (CGSize(width: 200, height: 120), CGSize(width: 200, height: 120)),
        ]
        for (imageSize, expected) in cases {
            let frame = ScreenshotController.pinnedImageFrame(imageSize: imageSize, frame: nil,
                pointSize: nil, visibleFrame: visibleFrame)
            XCTAssertEqual(frame, CGRect(origin: .zero, size: expected))
        }
    }

    func testScreenshotPointSizeSurvivesLibraryReopeningWithoutChangingPixels() async throws {
        let (model, defaults) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let image = try pixels(width: 641, height: 361)
        let pointSize = CGSize(width: 320.5, height: 180.5)
        let origin = CGPoint(x: -900.5, y: 210.5)
        let saved = try XCTUnwrap(model.storeScreenshot(image, tag: .green, pointSize: pointSize, pinOrigin: origin))
        XCTAssertEqual(saved.pointWidth, Double(pointSize.width))
        XCTAssertEqual(saved.pointHeight, Double(pointSize.height))
        XCTAssertEqual(saved.width, image.width)
        XCTAssertEqual(saved.height, image.height)

        let reopened = try LibraryStore(root: model.libraryRoot, defaults: defaults)
        addTeardownBlock { await reopened.cancelStorageWorkAndWait() }
        let recent = try XCTUnwrap(reopened.recentImage())
        XCTAssertEqual(recent.id, saved.id)
        XCTAssertEqual(recent.pointWidth, Double(pointSize.width))
        XCTAssertEqual(recent.pointHeight, Double(pointSize.height))
        XCTAssertEqual(recent.pinX, Double(origin.x))
        XCTAssertEqual(recent.pinY, Double(origin.y))
        XCTAssertEqual(recent.tag, .green)
        let reloaded = try reopened.loadImage(recent)
        XCTAssertEqual(reloaded.width, image.width)
        XCTAssertEqual(reloaded.height, image.height)
        XCTAssertEqual(try library.recentImage(), recent)
    }

    func testPrivateScreenshotDoesNotWritePointSizeOrReplaceEarlierHistory() throws {
        let (model, defaults) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let image = try pixels(width: 12, height: 8)
        let original = try XCTUnwrap(model.storeScreenshot(image, tag: .blue, pointSize: CGSize(width: 6, height: 4)))
        let files = try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted()
        let nextIndex = try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults)

        model.privacyMode = true
        XCTAssertNil(try model.storeScreenshot(image, tag: .red, pointSize: CGSize(width: 120, height: 80),
            pinOrigin: CGPoint(x: 123, y: 456)))

        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted(), files)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), nextIndex)
    }

    private func makeModel() throws -> (AppModel, UserDefaults) {
        let name = "Clipato.PinnedImageSizingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        XCTAssertNil(model.errorMessage)
        let library = try XCTUnwrap(model.library)
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        return (model, defaults)
    }

    private func pixels(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
