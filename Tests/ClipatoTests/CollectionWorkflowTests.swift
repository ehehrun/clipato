import AppKit
import CSQLite
import ClipatoCore
import os
import XCTest
@testable import Clipato

@MainActor
final class CollectionWorkflowTests: XCTestCase {
    func testDeletionImpactCountsDistinctCollectionsAndFollowsMembershipChanges() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let first = try library.addImage(pixels(red: 0.2), source: "截图")
        let second = try library.addImage(pixels(red: 0.8), source: "截图")
        let project = try library.createCollection(name: "项目")
        let reference = try library.createCollection(name: "参考")
        let unrelated = try library.createCollection(name: "其他")
        try library.addToCollection(project.id, assets: [.image(first.id), .image(second.id)])
        try library.addToCollection(reference.id, assets: [.image(first.id)])
        try library.addToCollection(unrelated.id, assets: [.image(second.id)])

        model.selected = [first.id]
        XCTAssertEqual(model.selectedImageCollectionCount, 2)
        model.selected = [first.id, second.id]
        XCTAssertEqual(model.selectedImageCollectionCount, 3)
        try library.removeFromCollection(project.id, assets: [.image(first.id)])
        XCTAssertEqual(model.selectedImageCollectionCount, 3, "同一收藏夹内有多张待删除图片时只计数一次")
        try library.removeFromCollection(project.id, assets: [.image(second.id)])
        XCTAssertEqual(model.selectedImageCollectionCount, 2)
        model.selected = []
        XCTAssertEqual(model.selectedImageCollectionCount, 0)
    }

    func testCompositionUsesVisibleOrderAndKeepsSourceCollectionAfterNavigation() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "项目")
        let other = try library.createCollection(name: "其他")
        let first = try library.addImage(pixels(red: 0.2), source: "截图", collectionID: source.id)
        let second = try library.addImage(pixels(red: 0.8), source: "截图", collectionID: source.id)
        model.selectCollection(source.id)
        model.compose(images: [first, second], collectionID: source.id)
        let collage = try XCTUnwrap(model.collage)
        XCTAssertEqual(collage.collectionID, source.id)
        XCTAssertEqual(try collage.images.map(redPixel), [51, 204])

        model.selectCollection(other.id)
        try model.saveCollage(pixels(red: 0.6), tag: .purple, mode: .grid)
        let savedCollage = try XCTUnwrap(library.images.first)
        XCTAssertEqual(savedCollage.source, "拼图")
        XCTAssertEqual(savedCollage.tag, .purple)
        XCTAssertTrue(library.assets(in: source.id).contains(.image(savedCollage.id)))
        XCTAssertTrue(library.assets(in: other.id).isEmpty)
        XCTAssertTrue(model.collageSaved)
        XCTAssertNotNil(model.collage, "The window owns closing after a successful save.")
        model.closeCollageWorkspace()

        model.composeLongScreenshot(images: [second, first], collectionID: source.id)
        let work = try XCTUnwrap(model.longScreenshot)
        XCTAssertEqual(try work.images.map(redPixel), [204, 51])
        model.selectCollection(other.id)
        try model.saveLongScreenshot(LongScreenshot.render(images: work.images, joins: [.init(overlap: 0)]), tag: .orange)
        let result = try XCTUnwrap(library.images.first)
        XCTAssertEqual(library.assets(in: source.id), [.image(first.id), .image(second.id), .image(savedCollage.id), .image(result.id)])
        XCTAssertTrue(library.assets(in: other.id).isEmpty)
        XCTAssertEqual(result.tag, .orange)
    }

    func testBothCompositionEntrypointsPreserveAnExistingDraftUntilItCloses() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let first = try library.addImage(pixels(red: 0.2), source: "截图")
        let second = try library.addImage(pixels(red: 0.8), source: "截图")
        let showRequests = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .clipatoShowCollageWorkspace, object: model, queue: nil) { _ in
            showRequests.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.compose(images: [first])
        let collageID = try XCTUnwrap(model.collage).id
        model.compose(images: [second])
        model.composeLongScreenshot(images: [second])
        XCTAssertEqual(model.collage?.id, collageID)
        XCTAssertEqual(try XCTUnwrap(model.collage).images.map(redPixel), [51])
        XCTAssertNil(model.longScreenshot)
        XCTAssertFalse(model.canCaptureFixedRegion)
        model.closeCollageWorkspace()

        model.composeLongScreenshot(images: [second])
        let longScreenshotID = try XCTUnwrap(model.longScreenshot).id
        model.composeLongScreenshot(images: [first])
        model.compose(images: [first])
        XCTAssertEqual(model.longScreenshot?.id, longScreenshotID)
        XCTAssertEqual(try XCTUnwrap(model.longScreenshot).images.map(redPixel), [204])
        XCTAssertNil(model.collage)
        XCTAssertFalse(model.canCaptureFixedRegion)
        model.closeCollageWorkspace()
        XCTAssertFalse(model.hasCollageWorkspace)
        XCTAssertTrue(model.canCaptureFixedRegion)
        XCTAssertEqual(showRequests.withLock { $0 }, 4)
    }

    func testExportUsesTheCurrentModeRatherThanTheEntryPoint() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "项目")
        let image = try pixels(red: 0.4)
        let original = try library.addImage(image, source: "截图", collectionID: source.id)

        model.compose(images: [original], collectionID: source.id)
        try model.saveCollage(image, tag: .green, mode: .longScreenshot)
        let longResult = try XCTUnwrap(library.images.first)
        XCTAssertEqual(longResult.source, "长截图")
        XCTAssertEqual(longResult.tag, .green)
        XCTAssertTrue(library.assets(in: source.id).contains(.image(longResult.id)))
        XCTAssertTrue(model.collageWorkspaceSaved)
        model.markCollageChanged()
        XCTAssertFalse(model.collageWorkspaceSaved)
        model.closeCollageWorkspace()

        model.composeLongScreenshot(images: [original], collectionID: source.id)
        for mode in [CollageWorkspaceMode.grid, .flow] {
            try model.saveCollage(image, tag: .orange, mode: mode)
            let result = try XCTUnwrap(library.images.first)
            XCTAssertEqual(result.source, "拼图")
            XCTAssertEqual(result.tag, .orange)
            XCTAssertTrue(library.assets(in: source.id).contains(.image(result.id)))
            XCTAssertTrue(model.longScreenshotSaved)
            model.markCollageChanged()
            XCTAssertFalse(model.longScreenshotSaved)
        }
        XCTAssertNil(model.batchExportMode)
        XCTAssertFalse(model.exportingImages)
    }

    func testFailedWorkbenchSaveRetainsTheUnsavedDraft() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let image = try pixels(red: 0.3)
        let original = try library.addImage(image, source: "截图")
        model.compose(images: [original])
        let id = try XCTUnwrap(model.collage).id
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER reject_workbench_save BEFORE INSERT ON images BEGIN SELECT RAISE(ABORT, 'workbench save denied'); END", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try model.saveCollage(image, tag: .red, mode: .grid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("workbench save denied"))
        }

        XCTAssertEqual(model.collage?.id, id)
        XCTAssertFalse(model.collageSaved)
        XCTAssertFalse(model.collageWorkspaceSaved)
        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.root.appendingPathComponent("Images").path), [original.id.uuidString])
        XCTAssertNil(model.batchExportMode)
    }

    func testClosingUnifiedWorkbenchClearsContinuousCaptureTemporaryFiles() throws {
        let model = try makeModel()
        let directory = model.libraryRoot.appendingPathComponent("Temporary Capture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let image = try pixels(red: 0.5)
        try LibraryStore.writePNG(image, to: directory.appendingPathComponent("1.png"))
        model.longScreenshot = LongScreenshotSelection(images: [image], tag: .purple, temporaryDirectory: directory)
        model.longScreenshotSaved = true

        model.closeCollageWorkspace()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(model.collage)
        XCTAssertNil(model.longScreenshot)
        XCTAssertFalse(model.collageSaved)
        XCTAssertFalse(model.longScreenshotSaved)
    }

    func testDeletedCollectionDetachesWorkbenchWithoutBlockingSave() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "项目")
        let original = try library.addImage(pixels(red: 0.4), source: "截图", collectionID: source.id)
        model.composeLongScreenshot(images: [original], collectionID: source.id)
        try library.deleteCollection(source.id)
        XCTAssertNotNil(model.longScreenshot)
        XCTAssertNil(model.longScreenshot?.collectionID)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(library.images, [original])
        try model.saveLongScreenshot(pixels(red: 0.7), tag: nil)
        XCTAssertEqual(library.images.count, 2)
        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertTrue(model.longScreenshotSaved)
    }

    func testSelectedKeyframesUseTimelineOrderWithoutImportingOriginals() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "录屏素材")
        let session = try makeSession(root: library.root)
        try library.setRecordingTag(.purple, for: session.directory)
        let originalFiles = try session.manifest.frames.indices.map { try Data(contentsOf: session.frameURL(at: $0)) }
        let composed = await model.composeKeyframes(session, indices: [2, 0], collectionID: source.id, longScreenshot: false)
        XCTAssertTrue(composed)
        let work = try XCTUnwrap(model.collage)
        XCTAssertEqual(work.collectionID, source.id)
        XCTAssertEqual(work.tag, .purple)
        XCTAssertEqual(try work.images.map(redPixel), [51, 204])
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertTrue(library.assets(in: source.id).isEmpty)
        XCTAssertFalse(model.preparingCollectionFrames)
        XCTAssertEqual(try session.manifest.frames.indices.map { try Data(contentsOf: session.frameURL(at: $0)) }, originalFiles)
    }

    func testKeyframeCompositionCannotReplaceEitherExistingWorkbenchDraft() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "录屏素材")
        let original = try library.addImage(pixels(red: 0.5), source: "截图")
        let session = try makeSession(root: library.root)
        for existingLongScreenshot in [false, true] {
            if existingLongScreenshot { model.composeLongScreenshot(images: [original]) }
            else { model.compose(images: [original]) }
            let collageID = model.collage?.id
            let longScreenshotID = model.longScreenshot?.id
            for requestedLongScreenshot in [false, true] {
                let opened = await model.composeKeyframes(session, indices: [0, 1], collectionID: source.id, longScreenshot: requestedLongScreenshot)
                XCTAssertFalse(opened)
                XCTAssertEqual(model.collage?.id, collageID)
                XCTAssertEqual(model.longScreenshot?.id, longScreenshotID)
                XCTAssertFalse(model.preparingCollectionFrames)
            }
            model.closeCollageWorkspace()
        }
    }

    func testMissingKeyframeDoesNotOpenPartialComposition() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "录屏素材")
        let session = try makeSession(root: library.root)
        try FileManager.default.removeItem(at: session.frameURL(at: 2))
        let composed = await model.composeKeyframes(session, indices: [0, 2], collectionID: source.id, longScreenshot: true)
        XCTAssertFalse(composed)
        XCTAssertNil(model.longScreenshot)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.preparingCollectionFrames)
        XCTAssertTrue(library.images.isEmpty)
    }

    func testCancelledKeyframePreparationDoesNotOpenWorkbench() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "录屏素材")
        let session = try makeSession(root: library.root)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.composeKeyframes(session, indices: [0, 1, 2], collectionID: source.id, longScreenshot: false)
        }
        let composed = await task.value
        XCTAssertFalse(composed)
        XCTAssertNil(model.collage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.preparingCollectionFrames)
    }

    func testKeyframesDoNotCompeteWithAnOpenExportSheet() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let source = try library.createCollection(name: "录屏素材")
        let session = try makeSession(root: library.root)
        model.batchExportMode = .files
        let composed = await model.composeKeyframes(session, indices: [0], collectionID: source.id, longScreenshot: false)
        XCTAssertFalse(composed)
        XCTAssertNil(model.collage)
        XCTAssertEqual(model.batchExportMode, .files)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.preparingCollectionFrames)
    }

    func testFramePathsRejectTraversalAbsoluteAndEscapingSymlink() throws {
        let model = try makeModel()
        let root = try XCTUnwrap(model.library).root
        let session = try makeSession(root: root)
        XCTAssertEqual(try session.frameURL(at: 0).lastPathComponent, "0.png")
        XCTAssertThrowsError(try session.frameURL(at: -1))
        XCTAssertThrowsError(try session.frameURL(at: 3))
        let outside = root.appendingPathComponent("outside.png")
        try LibraryStore.writePNG(pixels(red: 1), to: outside)
        try FileManager.default.createSymbolicLink(at: session.directory.appendingPathComponent("escape.png"), withDestinationURL: outside)
        for file in ["../outside.png", outside.path, "escape.png", "frames/not-an-image.txt"] {
            let invalid = SavedSession(id: session.id, directory: session.directory,
                                       manifest: manifest(id: session.id, files: [file]))
            XCTAssertThrowsError(try invalid.frameURL(at: 0), file)
        }
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.CollectionWorkflow.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        return AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults))
    }

    private func makeSession(root: URL) throws -> SavedSession {
        let id = UUID()
        let directory = root.appendingPathComponent("Sessions/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let files = (0..<3).map { "frames/\($0).png" }
        for (index, red) in [0.2, 0.4, 0.8].enumerated() {
            try LibraryStore.writePNG(pixels(red: red), to: directory.appendingPathComponent(files[index]))
        }
        return SavedSession(id: id, directory: directory, manifest: manifest(id: id, files: files))
    }

    private func manifest(id: UUID, files: [String]) -> KeyframeManifest {
        KeyframeManifest(id: id, createdAt: Date(), duration: 3, sampleRate: 1, threshold: 0.1,
                         width: 3, height: 2, frames: files.enumerated().map { .init(file: $0.element, time: Double($0.offset)) })
    }

    private func pixels(red: Double) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func redPixel(_ image: CGImage) throws -> UInt8 {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return try XCTUnwrap(context.data).load(as: UInt8.self)
    }
}
