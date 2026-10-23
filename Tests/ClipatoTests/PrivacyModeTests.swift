import AppKit
import Combine
import XCTest
@testable import Clipato

@MainActor
final class PrivacyModeTests: XCTestCase {
    func testStartingWithPrivacyAndMCPEnabledKeepsMCPOffAfterPrivacyIsDisabled() throws {
        let (model, defaults) = try makeModel(privacyMode: true, mcpEnabled: true)
        XCTAssertTrue(model.privacyMode)
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))

        model.privacyMode = false
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
    }

    func testEnablingPrivacyTurnsOffMCPAndDisablingPrivacyDoesNotRestoreIt() throws {
        let (model, defaults) = try makeModel()
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))

        model.privacyMode = true
        XCTAssertTrue(defaults.bool(forKey: "privacyMode"))
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))

        model.privacyMode = false
        XCTAssertFalse(defaults.bool(forKey: "privacyMode"))
        XCTAssertFalse(defaults.bool(forKey: MCPSettings.enabledKey))
        XCTAssertFalse(MCPSettings.isEnabled(in: defaults))
        defaults.set(true, forKey: MCPSettings.enabledKey)
        XCTAssertTrue(MCPSettings.isEnabled(in: defaults))
    }

    func testPrivacyDefaultsOffPersistsAndNormalCaptureResumesAfterDisabling() throws {
        let (model, defaults) = try makeModel()
        let library = try XCTUnwrap(model.library)
        XCTAssertFalse(model.privacyMode)
        let original = try XCTUnwrap(model.storeScreenshot(pixels(), tag: .blue))
        XCTAssertEqual(try library.recentImage(), original)

        model.privacyMode = true
        XCTAssertTrue(defaults.bool(forKey: "privacyMode"))
        let reopened = AppModel(root: model.libraryRoot, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        XCTAssertTrue(reopened.privacyMode)
        XCTAssertNil(try reopened.storeScreenshot(pixels(), tag: .red))
        XCTAssertEqual(try library.recentImage(), original)

        reopened.privacyMode = false
        let fresh = try XCTUnwrap(reopened.storeScreenshot(pixels(), tag: .green))
        XCTAssertEqual(fresh.tag, .green)
        XCTAssertEqual(fresh.source, "截图")
        XCTAssertEqual(try library.recentImage(), fresh)
        XCTAssertFalse(defaults.bool(forKey: "privacyMode"))
    }

    func testPrivateCaptureCreatesNoFilesOrRecordsAndPreservesCollectionsAndHistory() throws {
        let (model, _) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let original = try XCTUnwrap(model.storeScreenshot(pixels(), tag: .purple))
        let collection = try library.createCollection(name: "保留素材")
        try library.addToCollection(collection.id, assets: [.image(original.id)])
        let imageDirectory = model.libraryRoot.appendingPathComponent("Images")
        let files = try FileManager.default.subpathsOfDirectory(atPath: imageDirectory.path)
        let bytes = try Data(contentsOf: library.imageURL(original))
        let members = library.collectionMembers

        model.privacyMode = true
        for _ in 0..<3 { XCTAssertNil(try model.storeScreenshot(pixels(), tag: .orange)) }

        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(library.collectionMembers, members)
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: imageDirectory.path), files)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(original)), bytes)
    }

    func testPrivateCaptureDoesNotRequireAvailableVaultAndNormalCaptureReportsMissingVault() throws {
        let (model, _) = try makeModel()
        model.library = nil
        model.privacyMode = true
        XCTAssertNil(try model.storeScreenshot(pixels(), tag: nil))
        model.privacyMode = false
        XCTAssertThrowsError(try model.storeScreenshot(pixels(), tag: nil)) { error in
            XCTAssertEqual(error.localizedDescription, L("保管箱不可用，无法保存截图。"))
        }
    }

    func testPrivateContinuousCaptureKeepsTemporaryFramesOutOfVaultAndCleansOnClose() async throws {
        let frame = try pixels()
        let (model, _) = try makeModel(fixedCaptureImage: { _, _ in frame })
        let library = try XCTUnwrap(model.library)
        let original = try XCTUnwrap(model.storeScreenshot(frame, tag: nil))
        model.privacyMode = true
        let temporary = try model.beginFixedCapture(region: RecordingRegion(displayID: 1,
            rect: CGRect(x: 0, y: 0, width: 3, height: 2)), tag: .blue)
        let completed = expectation(description: "Private frames open in the workbench")
        let subscription = model.$longScreenshot.compactMap { $0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(model.longScreenshot?.images.count, 2)
        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted(), ["1.png", "2.png"])
        model.closeLongScreenshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testPrivateContinuousCaptureWorksWhenVaultIsUnavailable() async throws {
        let frame = try pixels()
        let (model, _) = try makeModel(fixedCaptureImage: { _, _ in frame })
        await model.library?.cancelStorageWorkAndWait()
        model.library = nil
        XCTAssertFalse(model.canCaptureFixedRegion)
        model.privacyMode = true
        XCTAssertTrue(model.canCaptureFixedRegion)
        let temporary = try model.beginFixedCapture(region: RecordingRegion(displayID: 1,
            rect: CGRect(x: 0, y: 0, width: 3, height: 2)), tag: nil)
        let completed = expectation(description: "Private capture needs no vault")
        let subscription = model.$longScreenshot.compactMap { $0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(model.longScreenshot?.images.count, 1)
        XCTAssertNil(model.errorMessage)
        model.closeLongScreenshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    private func makeModel(privacyMode: Bool = false, mcpEnabled: Bool = false,
                           fixedCaptureImage: ((RecordingRegion, [CGWindowID]) async throws -> CGImage)? = nil) throws -> (AppModel, UserDefaults) {
        let name = "Clipato.PrivacyModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        if privacyMode { defaults.set(true, forKey: "privacyMode") }
        if mcpEnabled { defaults.set(true, forKey: MCPSettings.enabledKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults,
                             fixedCaptureImage: fixedCaptureImage)
        XCTAssertNil(model.errorMessage)
        addTeardownBlock { @MainActor in
            await model.library?.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        return (model, defaults)
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
