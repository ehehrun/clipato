import AppKit
import Darwin
import XCTest
@testable import Clipato

@MainActor
final class AssetScanTests: XCTestCase {
    func testScanModesKeepMixedImagesAndVideosButExcludeKeyframeArchives() {
        let first = CollectionAsset.image(UUID())
        let video = CollectionAsset.video(URL(fileURLWithPath: "/tmp/clip.mp4"))
        let second = CollectionAsset.image(UUID())
        let assets = [first, .session(UUID()), video, second]
        XCTAssertEqual(AssetScanMode.duplicates.eligibleAssets(in: assets), [first, video, second])
        XCTAssertEqual(AssetScanMode.similarImages.eligibleAssets(in: assets), [first, second])
    }

    func testMetadataValidationRejectsAtomicReplacementEvenWithPreservedSizeAndDate() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("candidate.png")
        try Data("original".utf8).write(to: url)
        let previous = try scannedFileValues(at: url)
        XCTAssertNoThrow(try validateScannedFile(at: url, against: previous))

        try Data("modified".utf8).write(to: url, options: .atomic)
        var times = [previous.st_atimespec, previous.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)

        let current = try scannedFileValues(at: url)
        XCTAssertEqual(current.st_size, previous.st_size)
        XCTAssertEqual(current.st_mtimespec.tv_sec, previous.st_mtimespec.tv_sec)
        XCTAssertEqual(current.st_mtimespec.tv_nsec, previous.st_mtimespec.tv_nsec)
        XCTAssertThrowsError(try validateScannedFile(at: url, against: previous))
    }

    func testMissingCandidateRemainsAnErrorRatherThanAnEmptyResult() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("candidate.png")
        try Data([1, 2, 3]).write(to: url)
        let previous = try scannedFileValues(at: url)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try validateScannedFile(at: url, against: previous))
    }

    func testScanIsReadOnlyAndOnlyExplicitConfirmationCanUseItsAssets() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let first = images[0]
        let second = images[1]
        let source = library.imageURL(first)
        let original = try Data(contentsOf: source)

        model.prepareAssetScan([.image(second.id), .image(first.id)], mode: .duplicates)
        XCTAssertEqual(model.scanAssets, [.image(second.id), .image(first.id)])
        XCTAssertEqual(library.images.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)

        model.dismissAssetScan()
        XCTAssertThrowsError(try model.trashScannedAssets([(.image(first.id), source)]))
        XCTAssertEqual(library.images.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testListScanRoutesToImageProcessingAndPreservesSourceOrder() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let collection = try library.createCollection(name: "待整理")
        let scope = [CollectionAsset.image(images[1].id), .image(images[0].id)]
        try library.addToCollection(collection.id, assets: Set(scope))

        for source in [LibrarySection.images, .collections] {
            model.section = source
            model.selectedCollectionID = source == .collections ? collection.id : nil
            model.prepareAssetScan(scope, mode: .duplicates)

            XCTAssertEqual(model.section, .imageProcessing)
            XCTAssertEqual(model.imageProcessingRoute, .scanResults)
            XCTAssertEqual(model.scanAssets, scope)
            XCTAssertEqual(model.scanMode, .duplicates)
            XCTAssertEqual(Set(library.assets(in: collection.id)), Set(scope))
            model.dismissAssetScan()
        }
    }

    func testSelectingScanAndReturningRevokesPreviousDeletionScope() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let scope = images.map { CollectionAsset.image($0.id) }
        let source = library.imageURL(images[0])
        let original = try Data(contentsOf: source)
        model.prepareAssetScan(scope, mode: .duplicates)

        model.selectAssetScan(.similarImages)
        XCTAssertEqual(model.section, .imageProcessing)
        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.scan(.similarImages)))
        XCTAssertEqual(model.scanMode, .similarImages)
        XCTAssertEqual(model.selected, Set(images.map(\.id)), "Returning to inputs must restore the scan scope, including scans started outside the vault")
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertThrowsError(try model.trashScannedAssets([(.image(images[0].id), source)]))

        model.chooseVaultImageProcessing(.scan(.similarImages))
        XCTAssertEqual(model.imageProcessingRoute, .scanSelection)

        model.dismissAssetScan()
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertThrowsError(try model.trashScannedAssets([(.image(images[0].id), source)]))
        XCTAssertEqual(library.images.count, 2)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testInsufficientEligibleAssetsDoNotNavigateOrReplaceActiveScan() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let scope = images.map { CollectionAsset.image($0.id) }
        let video = CollectionAsset.video(library.root.appendingPathComponent("clip.mp4"))
        let insufficient = [scope[0], video, .session(UUID())]

        model.prepareAssetScan(insufficient, mode: .similarImages)
        XCTAssertEqual(model.section, .images)
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.scanAssets.isEmpty)

        model.prepareAssetScan(scope, mode: .duplicates)
        model.prepareAssetScan(insufficient, mode: .similarImages)
        XCTAssertEqual(model.imageProcessingRoute, .scanResults)
        XCTAssertEqual(model.scanMode, .duplicates)
        XCTAssertEqual(model.scanAssets, scope)
    }

    func testDeletionInProgressPreventsReplacingOrDismissingScan() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let scope = try addImages(to: library).map { CollectionAsset.image($0.id) }
        model.prepareAssetScan(scope, mode: .duplicates)
        model.scanDeletionInProgress = true

        model.selectAssetScan(.similarImages)
        XCTAssertEqual(model.imageProcessingRoute, .scanResults)
        XCTAssertEqual(model.scanMode, .duplicates)
        XCTAssertEqual(model.scanAssets, scope)

        model.dismissAssetScan()
        XCTAssertEqual(model.imageProcessingRoute, .scanResults)
        XCTAssertEqual(model.scanAssets, scope)

        model.prepareAssetScan(Array(scope.reversed()), mode: .similarImages)
        XCTAssertEqual(model.imageProcessingRoute, .scanResults)
        XCTAssertEqual(model.scanMode, .duplicates)
        XCTAssertEqual(model.scanAssets, scope)

        model.scanDeletionInProgress = false
        model.dismissAssetScan()
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.scanAssets.isEmpty)
    }

    func testSidebarNavigationPreservesScanUntilExplicitReturn() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let scope = try addImages(to: library).map { CollectionAsset.image($0.id) }
        model.prepareAssetScan(scope, mode: .similarImages)

        for destination in [LibrarySection.recordings, .appearance, .general, .images, .imageProcessing] {
            model.section = destination
            XCTAssertEqual(model.imageProcessingRoute, .scanResults)
            XCTAssertEqual(model.scanMode, .similarImages)
            XCTAssertEqual(model.scanAssets, scope)
        }

        model.dismissAssetScan()
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertEqual(library.images.count, 2)
    }

    private func addImages(to library: LibraryStore) throws -> [VaultImage] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        return try (0..<2).map { _ in try library.addImage(image, source: "截图") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.AssetScanTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeModel() throws -> AppModel {
        let directory = try temporaryDirectory()
        let name = "Clipato.AssetScanTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
    }
}
