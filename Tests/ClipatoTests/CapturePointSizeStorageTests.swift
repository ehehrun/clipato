import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CapturePointSizeStorageTests: XCTestCase {
    func testScreenshotPointSizeSurvivesSaveAndReopenWithoutChangingPixels() async throws {
        let (library, _) = try makeLibrary()
        let image = try pixels()
        let pointSize = CGSize(width: 2.25, height: 1.125)
        let item = try library.addImage(image, source: "截图", filename: "capture.png", tag: .purple, pointSize: pointSize,
                                        pinOrigin: CGPoint(x: -160.25, y: 0))

        XCTAssertEqual(item.pointWidth, 2.25)
        XCTAssertEqual(item.pointHeight, 1.125)
        XCTAssertEqual(item.pinX, -160.25)
        XCTAssertEqual(item.pinY, 0)
        XCTAssertEqual(item.width, image.width)
        XCTAssertEqual(item.height, image.height)
        let savedBytes = try Data(contentsOf: library.imageURL(item))
        await library.cancelStorageWorkAndWait()

        let reopened = try LibraryStore(root: library.root)
        let recent = try XCTUnwrap(reopened.recentImage())
        XCTAssertEqual(recent, item)
        let loaded = try reopened.loadImage(recent)
        XCTAssertEqual(loaded.width, image.width)
        XCTAssertEqual(loaded.height, image.height)
        XCTAssertEqual(try Data(contentsOf: reopened.imageURL(recent)), savedBytes)
        await reopened.cancelStorageWorkAndWait()
    }

    func testOrdinaryImagesAndImportsKeepUnknownPointDimensionsAndOriginalBytes() async throws {
        let (library, _) = try makeLibrary()
        let existing = try library.addImage(pixels(), source: "截图")
        XCTAssertNil(existing.pointWidth)
        XCTAssertNil(existing.pointHeight)
        let input = library.root.appendingPathComponent("imported.png")
        try LibraryStore.writePNG(pixels(), to: input)
        let originalBytes = try Data(contentsOf: input)

        try library.importImages([input])

        let imported = try XCTUnwrap(library.recentImage())
        XCTAssertNil(imported.pointWidth)
        XCTAssertNil(imported.pointHeight)
        XCTAssertNil(imported.pinX)
        XCTAssertNil(imported.pinY)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(imported)), originalBytes)
        await library.cancelStorageWorkAndWait()
        let reopened = try LibraryStore(root: library.root)
        XCTAssertEqual(try reopened.recentImage(), imported)
        XCTAssertTrue(reopened.images.allSatisfy { $0.pointWidth == nil && $0.pointHeight == nil })
        await reopened.cancelStorageWorkAndWait()
    }

    func testInvalidPointSizeDoesNotWriteAnAssetOrReplaceRecentImage() async throws {
        let (library, _) = try makeLibrary()
        let original = try library.addImage(pixels(), source: "截图", pointSize: CGSize(width: 2, height: 1))
        let imageDirectory = library.root.appendingPathComponent("Images")
        let files = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).sorted()
        let bytes = try Data(contentsOf: library.imageURL(original))
        for size in [CGSize(width: 0, height: 1), CGSize(width: 2, height: -1),
                     CGSize(width: CGFloat.infinity, height: 1), CGSize(width: 2, height: CGFloat.nan)] {
            XCTAssertThrowsError(try library.addImage(pixels(), source: "截图", pointSize: size)) { error in
                XCTAssertEqual(error.localizedDescription, LibraryError.invalidPointSize.localizedDescription)
            }
            XCTAssertEqual(library.images, [original])
            XCTAssertEqual(try library.recentImage(), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).sorted(), files)
            XCTAssertEqual(try Data(contentsOf: library.imageURL(original)), bytes)
        }
        await library.cancelStorageWorkAndWait()
    }

    func testPinPositionsAreIndependentAndRecentReadsObserveOtherConnections() async throws {
        let (library, defaults) = try makeLibrary()
        let first = try library.addImage(pixels(), source: "截图", tag: .green, pointSize: CGSize(width: 2, height: 1))
        let second = try library.addImage(pixels(), source: "截图", pinOrigin: CGPoint(x: 0, y: -90.125))
        let bytes = try Data(contentsOf: library.imageURL(first))
        let other = try LibraryStore(root: library.root, defaults: defaults, enforceStorageQuota: false)
        addTeardownBlock { @MainActor in await other.cancelStorageWorkAndWait() }

        try other.setPinPosition(CGPoint(x: -1920.25, y: 120.125), for: first.id)
        XCTAssertEqual(try library.recentImage(), second)
        let movedFirst = try XCTUnwrap(library.images.first { $0.id == first.id })
        XCTAssertEqual(movedFirst.pinX, -1920.25)
        XCTAssertEqual(movedFirst.pinY, 120.125)
        XCTAssertEqual(movedFirst.tag, first.tag)
        XCTAssertEqual(movedFirst.pointWidth, first.pointWidth)
        XCTAssertEqual(movedFirst.pointHeight, first.pointHeight)
        XCTAssertEqual(library.images.map(\.id), [second.id, first.id])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(movedFirst)), bytes)

        try other.setPinPosition(CGPoint(x: 42.5, y: -880.75), for: second.id)
        let recent = try XCTUnwrap(library.recentImage())
        XCTAssertEqual(recent.id, second.id)
        XCTAssertEqual(recent.pinX, 42.5)
        XCTAssertEqual(recent.pinY, -880.75)
        XCTAssertEqual(library.images.first { $0.id == first.id }, movedFirst)

        await other.cancelStorageWorkAndWait()
        await library.cancelStorageWorkAndWait()
        let reopened = try LibraryStore(root: library.root, defaults: defaults, enforceStorageQuota: false)
        addTeardownBlock { @MainActor in await reopened.cancelStorageWorkAndWait() }
        XCTAssertEqual(reopened.images, library.images)
        XCTAssertEqual(try reopened.recentImage(), recent)
        try reopened.clearOperationHistory()
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(reopened.images, library.images)
    }

    func testPrivacyModeDoesNotWritePinPositionsOrInitialOrigins() async throws {
        let (library, defaults) = try makeLibrary()
        let original = try library.addImage(pixels(), source: "截图", pinOrigin: CGPoint(x: -20.5, y: 80.25))
        defaults.set(true, forKey: "privacyMode")

        try library.setPinPosition(CGPoint(x: 600, y: -200), for: original.id)
        let privateImage = try library.addImage(pixels(), source: "截图", pinOrigin: CGPoint(x: 30, y: 40))

        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(library.images.first { $0.id == original.id }, original)
        XCTAssertNil(privateImage.pinX)
        XCTAssertNil(privateImage.pinY)
        await library.cancelStorageWorkAndWait()
        let reopened = try LibraryStore(root: library.root, defaults: defaults, enforceStorageQuota: false)
        addTeardownBlock { @MainActor in await reopened.cancelStorageWorkAndWait() }
        XCTAssertEqual(reopened.images, [privateImage, original])
        XCTAssertEqual(try reopened.recentImage(), original)
    }

    func testInvalidOriginsDoNotWriteFilesChangeImagesOrReplaceHistory() async throws {
        let (library, _) = try makeLibrary()
        let original = try library.addImage(pixels(), source: "截图", pinOrigin: CGPoint(x: 0, y: 0))
        let imageDirectory = library.root.appendingPathComponent("Images")
        let files = try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).sorted()
        let bytes = try Data(contentsOf: library.imageURL(original))

        for origin in [CGPoint(x: CGFloat.infinity, y: 0), CGPoint(x: 0, y: CGFloat.nan)] {
            XCTAssertThrowsError(try library.setPinPosition(origin, for: original.id)) { error in
                XCTAssertEqual(error.localizedDescription, LibraryError.invalidPinPosition.localizedDescription)
            }
            XCTAssertThrowsError(try library.addImage(pixels(), source: "截图", pinOrigin: origin)) { error in
                XCTAssertEqual(error.localizedDescription, LibraryError.invalidPinPosition.localizedDescription)
            }
            XCTAssertEqual(library.images, [original])
            XCTAssertEqual(try library.recentImage(), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imageDirectory.path).sorted(), files)
            XCTAssertEqual(try Data(contentsOf: library.imageURL(original)), bytes)
        }
        await library.cancelStorageWorkAndWait()
    }

    func testPositionWriteDoesNotRecreateAnImageDeletedByAnotherConnection() async throws {
        let (library, _) = try makeLibrary()
        let original = try library.addImage(pixels(), source: "截图")
        let database = try LibraryDatabase(root: library.root)
        try database.delete(original.id)

        XCTAssertThrowsError(try library.setPinPosition(CGPoint(x: 20, y: 40), for: original.id)) { error in
            guard case CollectionError.missingAsset = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(try database.images().isEmpty)
        XCTAssertNil(try library.recentImage())
        await library.cancelStorageWorkAndWait()
    }

    private func makeLibrary() throws -> (LibraryStore, UserDefaults) {
        let name = "Clipato.CapturePointSizeStorageTests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        let library = try LibraryStore(root: root, defaults: defaults, enforceStorageQuota: false)
        addTeardownBlock { @MainActor in await library.cancelStorageWorkAndWait() }
        return (library, defaults)
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
