import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CaptureFileNamingTests: XCTestCase {
    func testTokensUseStableDateFormatAndKeepLiteralPrefixAndExtension() throws {
        let rule = CaptureNamingRule(template: "订单_中文_{date}_{time}_{index:4}")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(try rule.filename(extension: "png", date: date, index: 7, timeZone: TimeZone(secondsFromGMT: 0)!),
                       "订单_中文_2023-11-14_22.13.20_0007.png")
        XCTAssertEqual(try CaptureNamingRule(template: "{index}").filename(extension: "mp4", index: 12345), "12345.mp4")
    }

    func testUnknownAndMalformedTokensFailWithoutTreatingThemAsLiteralText() {
        for template in ["{name}", "{date", "date}", "{{date}}", "{index:0}", "{index:13}", "{index:03}", "{index:+3}"] {
            XCTAssertThrowsError(try CaptureNamingRule(template: template).filename(extension: "png", index: 1), template)
        }
    }

    func testInvalidPathsAndByteLimitAreRejected() throws {
        for template in ["", "  ", ".", "..", ".hidden", "folder/name", "folder:name", "line\nname", String(repeating: "图", count: 84)] {
            XCTAssertThrowsError(try CaptureNamingRule(template: template).filename(extension: "png", index: 1), template)
        }
        XCTAssertEqual(try CaptureNamingRule(template: String(repeating: "a", count: 251)).filename(extension: "png", index: 1).utf8.count, 255)
        XCTAssertThrowsError(try CaptureNamingRule(template: "file").filename(extension: "../png", index: 1))
        XCTAssertThrowsError(try CaptureNamingRule(template: "{index}").filename(extension: "png", index: 0))
    }

    func testPreviewDoesNotConsumeNumbersAndScreenshotAndRecordingAreIndependent() throws {
        let defaults = try isolatedDefaults()
        let rule = try CaptureFileNaming.rule(for: .screenshot, defaults: defaults)
        for _ in 0..<3 {
            XCTAssertTrue(try rule.filename(extension: "png", index: CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults)).hasSuffix("_001.png"))
        }
        XCTAssertTrue(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults).hasSuffix("_001.png"))
        XCTAssertTrue(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults).hasSuffix("_002.png"))
        XCTAssertTrue(try CaptureFileNaming.nextFilename(for: .recording, extension: "mp4", defaults: defaults).hasSuffix("_001.mp4"))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), 3)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 2)
    }

    func testSavedRulesValidateTogetherAndDoNotResetCounters() throws {
        let defaults = try isolatedDefaults()
        _ = try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults)
        try CaptureFileNaming.save(screenshot: "凭证_{index:4}", recording: "演示_{index}", defaults: defaults)
        XCTAssertEqual(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults), "凭证_0002.png")
        XCTAssertThrowsError(try CaptureFileNaming.save(screenshot: "new_{index}", recording: "bad/{date}", defaults: defaults))
        XCTAssertEqual(try CaptureFileNaming.rule(for: .screenshot, defaults: defaults).template, "凭证_{index:4}")
        XCTAssertEqual(try CaptureFileNaming.rule(for: .recording, defaults: defaults).template, "演示_{index}")
    }

    func testRulesWithoutIndexDoNotConsumeNumbersAndFailedNamesDoNotReserve() throws {
        let defaults = try isolatedDefaults()
        try CaptureFileNaming.save(screenshot: "fixed", recording: "video", defaults: defaults)
        XCTAssertEqual(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults), "fixed.png")
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), 1)
        defaults.set("bad/{index}", forKey: CaptureNamingKind.screenshot.templateKey)
        XCTAssertThrowsError(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), 1)
    }

    func testCorruptSettingsAndCounterOverflowAreReported() throws {
        let defaults = try isolatedDefaults()
        defaults.set(42, forKey: CaptureNamingKind.screenshot.templateKey)
        XCTAssertThrowsError(try CaptureFileNaming.rule(for: .screenshot, defaults: defaults))
        for value: Any in [true, -1, "2", 1.5, Int.max] {
            defaults.set(value, forKey: "captureNaming.screenshot.index")
            XCTAssertThrowsError(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults))
        }
    }

    func testCaptureNameSurvivesReloadAndPrivacySkipsVaultAndNumberReservation() async throws {
        let defaults = try isolatedDefaults()
        try CaptureFileNaming.save(screenshot: "客户_{index:4}", recording: "演示_{index}", defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library)
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            try FileManager.default.removeItem(at: root)
        }
        let image = try pixels()
        let item = try XCTUnwrap(model.storeScreenshot(image, tag: .blue))
        XCTAssertEqual(item.filename, "客户_0001.png")
        XCTAssertEqual(item.tag, .blue)
        XCTAssertEqual(try library.recentImage(), item)
        let reopened = try LibraryStore(root: root, defaults: defaults)
        XCTAssertEqual(reopened.images.first?.filename, "客户_0001.png")
        XCTAssertEqual(try reopened.loadImage(item).width, 3)
        await reopened.cancelStorageWorkAndWait()

        model.privacyMode = true
        XCTAssertNil(try model.storeScreenshot(image, tag: nil))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), 2)
        model.library = nil
        // A private Save can name its output even when the vault is unavailable.
        XCTAssertEqual(try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults), "客户_0002.png")
        XCTAssertEqual(library.images, [item])
    }

    func testImportedAndExplicitOutputNamesRemainUnchanged() async throws {
        let defaults = try isolatedDefaults()
        try CaptureFileNaming.save(screenshot: "rule_{index}", recording: "video_{index}", defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = try LibraryStore(root: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            try FileManager.default.removeItem(at: root)
        }
        let original = root.appendingPathComponent("原始.PNG")
        try LibraryStore.writePNG(pixels(), to: original)
        try library.importImages([original])
        let explicit = try library.addImage(pixels(), source: "截图", filename: "cli-output.png")
        XCTAssertEqual(explicit.filename, "cli-output.png")
        XCTAssertTrue(library.images.contains { $0.filename == "原始.PNG" })
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults), 1)
    }

    func testNamedRecordingsAndCollectionsReloadFromExternalStorageUsingUUIDDirectories() async throws {
        let defaults = try isolatedDefaults()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appendingPathComponent("Vault")
        let external = directory.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let library = try LibraryStore(root: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            try FileManager.default.removeItem(at: directory)
        }
        try library.setStorageDirectory(external, for: .recordings)
        let videoDirectory = try library.newRecordingDirectory()
        let sessionDirectory = try library.newRecordingDirectory()
        for folder in [videoDirectory, sessionDirectory] {
            XCTAssertNotNil(UUID(uuidString: folder.lastPathComponent))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let video = videoDirectory.appendingPathComponent("演示_001.mp4")
        try Data("finalized video discovery fixture".utf8).write(to: video)
        let manifest = KeyframeManifest(id: try XCTUnwrap(UUID(uuidString: sessionDirectory.lastPathComponent)),
            createdAt: Date(), duration: 2, sampleRate: 2, threshold: 0.025, width: 64, height: 48,
            frames: [.init(file: "frames/000001.png", time: 0)], name: "演示_002")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: sessionDirectory.appendingPathComponent("manifest.json"))
        try library.reloadSessions()
        let collection = try library.createCollection(name: "演示")
        let assets: Set<CollectionAsset> = [.video(video.resolvingSymlinksInPath()), .session(manifest.id)]
        try library.addToCollection(collection.id, assets: assets)
        let reloaded = try LibraryStore(root: root, defaults: defaults)
        XCTAssertEqual(reloaded.videos, [video.resolvingSymlinksInPath()])
        XCTAssertEqual(reloaded.sessions.first?.manifest.name, "演示_002")
        XCTAssertEqual(reloaded.collectionMembers[collection.id], assets)
        await reloaded.cancelStorageWorkAndWait()
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "Clipato.CaptureFileNamingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
