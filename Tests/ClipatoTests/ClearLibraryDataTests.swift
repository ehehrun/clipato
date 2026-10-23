import AppKit
import Combine
import XCTest
@testable import Clipato

@MainActor
final class ClearLibraryDataTests: XCTestCase {
    func testConfirmedClearRemovesSelectionAndHistoryPreservesSettingsAndBlocksNewCapture() async throws {
        let (model, defaults, trash) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let image = try pixels()
        let items = try (0..<2).map { try library.addImage(image, source: "截图", filename: "\($0).png") }
        let collection = try library.createCollection(name: "待删除收藏夹")
        try library.addToCollection(collection.id, assets: Set(items.map { .image($0.id) }))
        model.selected = Set(items.map(\.id))
        model.privacyMode = true
        let completed = expectation(description: "Confirmed clear completes")
        let subscription = model.$clearingLibraryData.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        XCTAssertTrue(model.canClearLibraryData)
        model.clearLibraryData(options: LibraryCleanupOptions())
        XCTAssertTrue(model.clearingLibraryData)
        XCTAssertFalse(model.canClearLibraryData)
        XCTAssertFalse(model.canCaptureFixedRegion)
        model.capture(region: true)
        model.captureFixedRegion()
        model.toggleRecording()
        model.selectImageProcessing(.compress)
        model.clearLibraryData(options: LibraryCleanupOptions())
        XCTAssertFalse(model.capturing)
        XCTAssertFalse(model.recordingBusy)
        XCTAssertNil(model.imageProcessingRoute)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertNil(try library.recentImage())
        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertTrue(library.assets(in: collection.id).isEmpty)
        XCTAssertTrue(defaults.bool(forKey: "privacyMode"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.notice, L("数据清理完成"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 2)
        for item in items { XCTAssertFalse(FileManager.default.fileExists(atPath: library.imageURL(item).path)) }
    }

    func testFailureRetainsRemainingSelectionAndFilesAndDoesNotReportSuccess() async throws {
        let (model, _, trash) = try makeModel(failingTrash: true)
        let library = try XCTUnwrap(model.library)
        let item = try library.addImage(pixels(), source: "截图")
        let bytes = try Data(contentsOf: library.imageURL(item))
        model.selected = [item.id]
        let completed = expectation(description: "Failed clear releases busy state")
        let subscription = model.$clearingLibraryData.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.clearLibraryData(options: LibraryCleanupOptions())
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(model.selected, [item.id])
        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.errorMessage, L("清空未完成：\(CocoaError(.fileWriteNoPermission).localizedDescription)"))
        XCTAssertTrue(model.canClearLibraryData)
    }

    func testActiveCaptureRecordingEditorOrProcessingCannotStartClear() throws {
        let (model, _, _) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let image = try pixels()
        let item = try library.addImage(image, source: "截图")

        model.capturing = true
        XCTAssertFalse(model.canClearLibraryData)
        model.clearLibraryData(options: LibraryCleanupOptions())
        model.capturing = false
        model.recordingBusy = true
        XCTAssertFalse(model.canClearLibraryData)
        model.clearLibraryData(options: LibraryCleanupOptions())
        model.recordingBusy = false
        model.editing = EditingImage(image: image)
        XCTAssertFalse(model.canClearLibraryData)
        model.clearLibraryData(options: LibraryCleanupOptions())
        model.editing = nil
        model.selectImageProcessing(.compress)
        XCTAssertFalse(model.canClearLibraryData)
        model.clearLibraryData(options: LibraryCleanupOptions())
        model.dismissImageProcessing()

        XCTAssertTrue(model.canClearLibraryData)
        XCTAssertFalse(model.clearingLibraryData)
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(try library.recentImage(), item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(item).path))
    }

    func testCollectionsOnlyDeletesFoldersAndKeepsMediaSelectionAndHistory() async throws {
        let (model, _, trash) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let item = try library.addImage(pixels(), source: "截图")
        let folder = try library.createCollection(name: "仅删除文件夹")
        try library.addToCollection(folder.id, assets: [.image(item.id)])
        model.selected = [item.id]
        let completed = expectation(description: "Selected collection cleanup completes")
        let subscription = model.$clearingLibraryData.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.clearLibraryData(options: LibraryCleanupOptions(images: false, recordings: false, collections: true, history: false))
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(model.selected, [item.id])
        XCTAssertEqual(try library.recentImage(), item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(item).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        XCTAssertEqual(model.notice, L("数据清理完成"))
        XCTAssertNil(model.errorMessage)
    }

    func testNoCheckedOptionsDoesNotStartCleanupOrChangeHistory() throws {
        let (model, _, _) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let item = try library.addImage(pixels(), source: "截图")

        model.clearLibraryData(options: LibraryCleanupOptions(images: false, recordings: false, collections: false, history: false))

        XCTAssertFalse(model.clearingLibraryData)
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(try library.recentImage(), item)
        XCTAssertNil(model.notice)
        XCTAssertNil(model.errorMessage)
    }

    func testCollectionsOnlyDoesNotLetFinalQuotaRefreshDeleteUnselectedImages() async throws {
        let (model, _, trash) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let item = try library.addImage(pixels(), source: "截图")
        let folder = try library.createCollection(name: "容量保护")
        try library.addToCollection(folder.id, assets: [.image(item.id)])
        try library.updateStoragePolicy(LibraryStoragePolicy(maximumBytes: 1, automaticallyRemoveOldestImages: true,
            protectTaggedImages: false, protectCollectedImages: true, keepRecentDays: 0))
        await library.refreshStorageUsage()
        XCTAssertEqual(library.images, [item])
        let completed = expectation(description: "Collection cleanup refreshes statistics without applying quota")
        let subscription = model.$clearingLibraryData.dropFirst().filter { !$0 }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.clearLibraryData(options: LibraryCleanupOptions(images: false, recordings: false, collections: true, history: false))
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertEqual(library.images, [item])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(item).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        XCTAssertTrue(library.storagePolicy.automaticallyRemoveOldestImages)
        XCTAssertGreaterThan(try XCTUnwrap(library.storageUsage).mediaBytes, 1)
        XCTAssertNil(model.errorMessage)
    }

    private func makeModel(failingTrash: Bool = false) throws -> (AppModel, UserDefaults, URL) {
        let name = "Clipato.ClearLibraryDataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let root = directory.appendingPathComponent("Vault")
        let trash = directory.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try LibraryStore(root: root, defaults: defaults, trashImageDirectory: { source in
            if failingTrash { throw CocoaError(.fileWriteNoPermission) }
            let destination = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        })
        model.library = library
        addTeardownBlock { @MainActor in
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        return (model, defaults, trash)
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}
