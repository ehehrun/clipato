import AppKit
import XCTest
@testable import Clipato

@MainActor
final class PrivacyStorageTests: XCTestCase {
    func testPrivacySuppressesNewHistoryWhileKeepingExplicitVaultSavesAndEarlierHistory() throws {
        let directory = try temporaryDirectory()
        let defaults = try temporaryDefaults()
        XCTAssertFalse(defaults.bool(forKey: "privacyMode"))
        let library = try makeLibrary(root: directory.appendingPathComponent("Vault"), defaults: defaults)
        let original = try library.addImage(pixels(), source: "截图", filename: "earlier.png")
        let collection = try library.createCollection(name: "Explicit saves")
        let input = directory.appendingPathComponent("external.png")
        try LibraryStore.writePNG(pixels(), to: input)
        let bytes = try Data(contentsOf: input)

        defaults.set(true, forKey: "privacyMode")
        let saved = try library.addImage(pixels(), source: "拼图", filename: "manual.png", collectionID: collection.id)
        try library.importImages([input])
        try library.rememberImage(saved.id)

        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(library.images.count, 3)
        XCTAssertEqual(library.assets(in: collection.id), [.image(saved.id)])
        let imported = try XCTUnwrap(library.images.first)
        XCTAssertEqual(imported.source, "导入")
        XCTAssertEqual(try Data(contentsOf: library.imageURL(imported)), bytes)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let reopened = try makeLibrary(root: library.root, defaults: defaults)
        XCTAssertEqual(try reopened.recentImage(), original)
        XCTAssertEqual(reopened.images, library.images)

        defaults.set(false, forKey: "privacyMode")
        try reopened.rememberImage(saved.id)
        XCTAssertEqual(try library.recentImage(), saved)
        let normal = try reopened.addImage(pixels(), source: "截图", filename: "normal.png")
        XCTAssertEqual(try library.recentImage(), normal)
    }

    func testReopeningWithPersistedPrivacyKeepsClearedHistoryEmpty() throws {
        let directory = try temporaryDirectory()
        let suite = "Clipato-Privacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacyMode")
        let library = try makeLibrary(root: directory.appendingPathComponent("Vault"), defaults: defaults)
        let saved = try library.addImage(pixels(), source: "截图", filename: "manual.png")
        try library.rememberImage(saved.id)
        XCTAssertNil(try library.recentImage())

        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(reopenedDefaults.bool(forKey: "privacyMode"))
        let reopened = try makeLibrary(root: library.root, defaults: reopenedDefaults)
        _ = try reopened.addImage(pixels(), source: "长图", filename: "another-manual.png")
        XCTAssertNil(try reopened.recentImage())
        XCTAssertEqual(reopened.images.count, 2)

        reopenedDefaults.set(false, forKey: "privacyMode")
        let input = directory.appendingPathComponent("new-import.png")
        try LibraryStore.writePNG(pixels(), to: input)
        try reopened.importImages([input])
        XCTAssertEqual(try reopened.recentImage()?.filename, input.lastPathComponent)
    }

    func testPrivateKeyframeImportPreservesHistoryAndStillImportsEveryFrame() async throws {
        let directory = try temporaryDirectory()
        let defaults = try temporaryDefaults()
        let library = try makeLibrary(root: directory.appendingPathComponent("Vault"), defaults: defaults)
        let original = try library.addImage(pixels(), source: "截图", filename: "earlier.png")
        let sessionDirectory = directory.appendingPathComponent("Recording")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
        for name in ["first.png", "second.png"] {
            try LibraryStore.writePNG(pixels(), to: sessionDirectory.appendingPathComponent(name))
        }
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 2, sampleRate: 1,
                                        threshold: 0.025, width: 3, height: 2,
                                        frames: [.init(file: "first.png", time: 0), .init(file: "second.png", time: 1)])
        let session = SavedSession(id: manifest.id, directory: sessionDirectory, manifest: manifest)
        defaults.set(true, forKey: "privacyMode")

        let count = try await library.importKeyframes(session)

        XCTAssertEqual(count, 2)
        XCTAssertEqual(library.images.map(\.filename), ["first.png", "second.png", "earlier.png"])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try makeLibrary(root: library.root, defaults: defaults).recentImage(), original)
        for image in library.images where image.source == "关键帧" {
            XCTAssertEqual(try Data(contentsOf: library.imageURL(image)),
                           try Data(contentsOf: sessionDirectory.appendingPathComponent(image.filename)))
        }
    }

    private func makeLibrary(root: URL, defaults: UserDefaults) throws -> LibraryStore {
        let library = try LibraryStore(root: root, defaults: defaults)
        addTeardownBlock { await library.cancelStorageWorkAndWait() }
        return library
    }

    private func temporaryDefaults() throws -> UserDefaults {
        let suite = "Clipato-Privacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-PrivacyStorage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
