import AppKit
import XCTest
@testable import Clipato

@MainActor
final class ImageProcessingRouteTests: XCTestCase {
    func testEveryOverviewEntryRequiresAnExplicitSourceChoice() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        model.selected = [images[1].id]
        let capabilities: [ImageProcessingCapability] = [.tool(.compress), .tool(.resize), .tool(.convert),
                                                       .tool(.grid), .rename, .scan(.duplicates), .scan(.similarImages)]
        for capability in capabilities {
            model.selectImageProcessingSource(capability)
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(capability))
            XCTAssertNil(model.imageProcessingSource)
            XCTAssertNil(model.batchExportMode)
            XCTAssertTrue(model.externalRenameURLs.isEmpty)
            XCTAssertTrue(model.externalScanURLs.isEmpty)
            XCTAssertEqual(model.selected, [images[1].id])
            model.chooseVaultImageProcessing(capability)
            XCTAssertEqual(model.imageProcessingSource, .vault)
            XCTAssertNotEqual(model.imageProcessingRoute, .sourceSelection(capability))
        }
        XCTAssertEqual(library.images.count, 2)
    }

    func testExternalCapabilitiesKeepSourceOrderWithoutImportingAndReturnToSourceChoice() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let originals = try addImages(to: library)
        let urls = try externalImages(from: originals, in: library).reversed().map { $0 }
        let capabilities: [ImageProcessingCapability] = [.tool(.compress), .tool(.resize), .tool(.convert),
                                                       .tool(.grid), .rename, .scan(.duplicates), .scan(.similarImages)]
        for capability in capabilities {
            let inputs = capability == .tool(.grid) ? [urls[0]] : urls
            model.selectImageProcessingSource(capability)
            try model.prepareExternalImages(inputs, for: capability)
            XCTAssertEqual(model.imageProcessingSource, .files)
            XCTAssertTrue(model.batchRenameAssets.isEmpty)
            XCTAssertTrue(model.scanAssets.isEmpty)
            switch capability {
            case .tool(let tool):
                XCTAssertEqual(model.imageProcessingRoute, .processing(tool))
                XCTAssertEqual(model.batchExportImages, inputs)
            case .rename:
                XCTAssertEqual(model.imageProcessingRoute, .renamePreview)
                XCTAssertEqual(try model.batchRenameSourceURLs(), inputs)
            case .scan:
                XCTAssertEqual(model.imageProcessingRoute, .scanResults)
                XCTAssertEqual(model.externalScanURLs, inputs)
            }
            model.returnToImageProcessingInput()
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(capability))
            XCTAssertNil(model.imageProcessingSource)
            XCTAssertTrue(model.externalRenameURLs.isEmpty)
            XCTAssertTrue(model.externalScanURLs.isEmpty)
        }
        XCTAssertEqual(Set(library.images), Set(originals))
    }

    func testInvalidExternalCardinalityKeepsTheSourcePageAndExistingFiles() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let urls = try externalImages(from: images, in: library)
        for capability in [ImageProcessingCapability.rename, .scan(.duplicates), .scan(.similarImages)] {
            model.selectImageProcessingSource(capability)
            XCTAssertThrowsError(try model.prepareExternalImages([urls[0], urls[0]], for: capability))
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(capability))
        }
        model.selectImageProcessing(.grid)
        XCTAssertThrowsError(try model.prepareExternalImages(urls, for: .tool(.grid)))
        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.tool(.grid)))
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testExternalRenameChangesOnlyChosenFilesAndKeepsTheVaultIndexUntouched() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let inputs = Array(try externalImages(from: images, in: library).reversed())
        let bytes = try inputs.map { try Data(contentsOf: $0) }
        try model.prepareExternalImages(inputs, for: .rename)

        try model.batchRename(rule: .init(prefix: "External_", start: 3, increment: 2, digits: 2))

        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.externalRenameURLs.isEmpty)
        for (index, input) in inputs.enumerated() {
            let output = input.deletingLastPathComponent().appendingPathComponent(index == 0 ? "External_03.png" : "External_05.png")
            XCTAssertEqual(try Data(contentsOf: output), bytes[index])
            XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        }
        XCTAssertEqual(Set(library.images), Set(images))
        XCTAssertTrue(images.allSatisfy { FileManager.default.fileExists(atPath: library.imageURL($0).path) })
    }

    func testExternalMutationCannotBypassVaultIndexThroughDirectPathsOrSymlinks() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let external = try externalImages(from: images, in: library)
        let link = external[0].deletingLastPathComponent().appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.imageURL(images[0]))
        for capability in [ImageProcessingCapability.rename, .scan(.duplicates), .scan(.similarImages)] {
            model.selectImageProcessingSource(capability)
            XCTAssertThrowsError(try model.prepareExternalImages(images.map(library.imageURL), for: capability))
            XCTAssertThrowsError(try model.prepareExternalImages([link, external[1]], for: capability))
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(capability))
        }
        XCTAssertTrue(images.allSatisfy { FileManager.default.fileExists(atPath: library.imageURL($0).path) })
    }

    func testExternalScanDeletionScopeRejectsUnselectedFilesAndIsRevokedOnNavigation() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library, count: 3)
        let urls = try externalImages(from: images, in: library)
        try model.prepareExternalImages(Array(urls.prefix(2)), for: .scan(.duplicates))
        XCTAssertThrowsError(try model.trashScannedFiles([urls[2]]))
        model.selectImageProcessing(.compress)
        XCTAssertTrue(model.externalScanURLs.isEmpty)
        XCTAssertThrowsError(try model.trashScannedFiles([urls[0]]))
        XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testExternalMutationProtectsCustomStorageAndHardLinkAliases() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let original = try addImages(to: library)
        let external = try externalImages(from: original, in: library)
        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.CustomImages.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: custom) }
        try library.setStorageDirectory(custom, for: .screenshots)
        let customImages = try addImages(to: library)
        let alias = external[0].deletingLastPathComponent().appendingPathComponent("hard-linked.png")
        try FileManager.default.linkItem(at: library.imageURL(customImages[0]), to: alias)
        for capability in [ImageProcessingCapability.rename, .scan(.duplicates), .scan(.similarImages)] {
            model.selectImageProcessingSource(capability)
            XCTAssertThrowsError(try model.prepareExternalImages(customImages.map(library.imageURL), for: capability))
            XCTAssertThrowsError(try model.prepareExternalImages([alias, external[1]], for: capability))
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(capability))
        }
        XCTAssertTrue(customImages.allSatisfy { FileManager.default.fileExists(atPath: library.imageURL($0).path) })
    }

    func testExternalNameExchangeRefreshesPreviouslyCachedThumbnails() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library, varyingColors: true)
        let urls = try externalImages(from: images, in: library)
        let first = try await library.thumbnail(at: urls[0])
        let second = try await library.thumbnail(at: urls[1])
        let firstBytes = try XCTUnwrap(first.tiffRepresentation)
        let secondBytes = try XCTUnwrap(second.tiffRepresentation)
        XCTAssertNotEqual(firstBytes, secondBytes)
        try model.prepareExternalImages(Array(urls.reversed()), for: .rename)

        try model.batchRename(rule: .init(prefix: "Input_", start: 0, increment: 1, digits: 0))
        await Task.yield()

        let refreshedFirst = try await library.thumbnail(at: urls[0])
        let refreshedSecond = try await library.thumbnail(at: urls[1])
        XCTAssertEqual(refreshedFirst.tiffRepresentation, secondBytes)
        XCTAssertEqual(refreshedSecond.tiffRepresentation, firstBytes)
    }

    func testLibraryProcessingOpensConsoleRouteInTheSuppliedSourceOrder() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let ordered = Array(images.reversed())

        for tool in [ImageTool.compress, .resize, .convert] {
            model.section = .collections
            model.prepareImageExport(ordered, mode: .files, tool: tool)

            XCTAssertEqual(model.section, .imageProcessing)
            XCTAssertEqual(model.imageProcessingRoute, .processing(tool))
            XCTAssertEqual(model.batchExportImages, ordered.map(library.imageURL))
            XCTAssertEqual(model.batchImageTool, tool)
            XCTAssertEqual(model.batchExportMode, .files)
            model.dismissImageProcessing()
        }
        XCTAssertEqual(library.images.count, images.count, "Opening parameter pages must not import or rewrite originals")
    }

    func testOrdinaryFileZipAndVideoExportsRetainTheirModalFlow() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)

        for mode in BatchExportMode.allCases {
            model.prepareImageExport([images[1]], mode: .files, tool: .resize)
            model.section = .images
            model.prepareImageExport(images, mode: mode)

            XCTAssertNil(model.imageProcessingRoute)
            XCTAssertEqual(model.section, .images)
            XCTAssertEqual(model.batchExportMode, mode)
            XCTAssertEqual(model.batchExportImages, images.map(library.imageURL))
            XCTAssertNil(model.batchImageTool)
            model.dismissImageExport()
        }
    }

    func testGridRejectsMultipleInputsWithoutReplacingTheCurrentDraft() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        model.prepareImageExport([images[1]], mode: .files, tool: .grid)
        XCTAssertEqual(model.imageProcessingRoute, .processing(.grid))

        model.prepareImageExport(images, mode: .files, tool: .grid)

        XCTAssertEqual(model.imageProcessingRoute, .processing(.grid))
        XCTAssertEqual(model.batchExportImages, [library.imageURL(images[1])])
        XCTAssertEqual(model.batchImageTool, .grid)
        XCTAssertEqual(model.batchExportMode, .files)
        XCTAssertNotNil(model.errorMessage)
    }

    func testReturningFromParametersRestoresSourceSelectionAndReleasesExportDraft() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library, count: 3)
        let scope = [images[2], images[0]]
        model.prepareImageExport(scope, mode: .files, tool: .resize)
        model.selected = [images[1].id]

        model.returnToImageProcessingInput()

        XCTAssertEqual(model.imageProcessingRoute, .toolSelection(.resize))
        XCTAssertEqual(model.selected, Set(scope.map(\.id)))
        XCTAssertNil(model.batchExportMode)
        XCTAssertNil(model.batchImageTool)
        XCTAssertTrue(model.batchExportImages.isEmpty)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
    }

    func testSelectingAnotherToolRevokesThePreviousScanDeletionScope() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let scanned = images.map { CollectionAsset.image($0.id) }
        let source = library.imageURL(images[0])
        let original = try Data(contentsOf: source)
        model.prepareAssetScan(scanned, mode: .duplicates)

        model.selectImageProcessing(.compress)

        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.tool(.compress)))
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertThrowsError(try model.trashScannedAssets([(.image(images[0].id), source)]))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertEqual(library.images.count, images.count)
    }

    func testRenamePickerPreservesSelectionAndReturningFromPreviewRestoresItsScope() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library, count: 3)
        model.selected = [images[1].id]
        model.prepareImageExport([images[0]], mode: .files, tool: .convert)

        model.selectBatchRename()
        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.rename))
        model.chooseVaultImageProcessing(.rename)

        XCTAssertEqual(model.imageProcessingRoute, .renameSelection)
        XCTAssertEqual(model.selected, [images[1].id])
        XCTAssertNil(model.batchExportMode)
        XCTAssertTrue(model.batchExportImages.isEmpty)
        let assets = [CollectionAsset.image(images[2].id), .image(images[0].id)]
        model.prepareBatchRename(assets)
        XCTAssertEqual(model.section, .imageProcessing)
        XCTAssertEqual(model.imageProcessingRoute, .renamePreview)
        XCTAssertEqual(model.batchRenameAssets, assets)
        model.selected = [images[1].id]

        model.returnToImageProcessingInput()

        XCTAssertEqual(model.imageProcessingRoute, .renameSelection)
        XCTAssertEqual(model.selected, [images[2].id, images[0].id])
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
    }

    func testRenameFailureKeepsPreviewAndSuccessfulRenameReturnsToOverview() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        let assets = [CollectionAsset.image(images[1].id), .image(images[0].id)]
        model.prepareBatchRename(assets)

        XCTAssertThrowsError(try model.batchRename(rule: .init(prefix: "Order_", start: 7, increment: 0, digits: 2)))
        XCTAssertEqual(model.imageProcessingRoute, .renamePreview)
        XCTAssertEqual(model.batchRenameAssets, assets)
        XCTAssertEqual(library.images.first { $0.id == images[0].id }?.filename, images[0].filename)

        try model.batchRename(rule: .init(prefix: "Order_", start: 7, increment: 2, digits: 2))

        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
        XCTAssertEqual(library.images.first { $0.id == images[1].id }?.filename, "Order_07.png")
        XCTAssertEqual(library.images.first { $0.id == images[0].id }?.filename, "Order_09.png")
    }

    func testVideoRenameUsesTheSharedPreviewAndDismissesWithoutChangingFiles() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let videos = try addVideos(to: library)
        let originals = try videos.map { try Data(contentsOf: $0) }
        model.section = .recordings
        model.prepareBatchRename(videos.reversed().map(CollectionAsset.video))

        XCTAssertEqual(model.section, .imageProcessing)
        XCTAssertEqual(model.imageProcessingRoute, .renamePreview)
        XCTAssertEqual(model.batchRenameAssets, videos.reversed().map(CollectionAsset.video))

        model.dismissImageProcessing()

        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
        XCTAssertNil(model.batchExportMode)
        for (index, video) in videos.enumerated() { XCTAssertEqual(try Data(contentsOf: video), originals[index]) }
    }

    func testSidebarNavigationRetainsParametersUntilExplicitDismissal() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        model.prepareImageExport(images, mode: .files, tool: .convert)

        for destination in [LibrarySection.images, .recordings, .appearance, .general, .imageProcessing] {
            model.section = destination
            XCTAssertEqual(model.imageProcessingRoute, .processing(.convert))
            XCTAssertEqual(model.batchExportImages, images.map(library.imageURL))
            XCTAssertEqual(model.batchImageTool, .convert)
        }

        model.dismissImageProcessing()
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertNil(model.batchExportMode)
        XCTAssertNil(model.batchImageTool)
        XCTAssertTrue(model.batchExportImages.isEmpty)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
    }

    func testDeletionInProgressPreventsChangingOrDismissingTheRoute() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        model.prepareImageExport(images, mode: .files, tool: .resize)
        model.scanDeletionInProgress = true

        XCTAssertTrue(model.imageProcessingNavigationBlocked)
        attemptNavigation(in: model, images: images)
        XCTAssertEqual(model.section, .imageProcessing)
        XCTAssertEqual(model.imageProcessingRoute, .processing(.resize))
        XCTAssertEqual(model.batchExportImages, images.map(library.imageURL))
        XCTAssertEqual(model.batchImageTool, .resize)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)

        model.scanDeletionInProgress = false
        XCTAssertFalse(model.imageProcessingNavigationBlocked)
        model.dismissImageProcessing()
        XCTAssertNil(model.imageProcessingRoute)
    }

    func testRunningExportPreventsRouteReplacementUntilItFinishes() async throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let images = try addImages(to: library)
        model.prepareImageExport(images, mode: .files, tool: .compress)
        let session = try corruptSession(in: library.root)
        model.exportSessionToVault(session)

        XCTAssertTrue(model.isExporting)
        XCTAssertTrue(model.imageProcessingNavigationBlocked)
        attemptNavigation(in: model, images: images)
        XCTAssertEqual(model.imageProcessingRoute, .processing(.compress))
        XCTAssertEqual(model.batchExportImages, images.map(library.imageURL))
        XCTAssertEqual(model.batchImageTool, .compress)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)

        await model.cancelExportAndWait()
        XCTAssertFalse(model.imageProcessingNavigationBlocked)
        model.dismissImageProcessing()
        XCTAssertNil(model.imageProcessingRoute)
    }

    private func attemptNavigation(in model: AppModel, images: [VaultImage]) {
        model.selectImageProcessing(.grid)
        model.chooseVaultImageProcessing(.tool(.grid))
        model.chooseVaultImageProcessing(.rename)
        model.selectBatchRename()
        model.returnToImageProcessingInput()
        model.dismissImageProcessing()
        model.dismissAssetScan()
        model.selectAssetScan(.similarImages)
        model.prepareAssetScan(images.map { .image($0.id) }, mode: .duplicates)
        model.prepareBatchRename(images.map { .image($0.id) })
        model.prepareImageExport([images[0]], mode: .files, tool: .grid)
        model.prepareImageExport(images, mode: .zip)
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.ImageProcessingRouteTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library)
        addTeardownBlock { @MainActor in
            await model.cancelExportAndWait()
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        return model
    }

    private func addImages(to library: LibraryStore, count: Int = 2, varyingColors: Bool = false) throws -> [VaultImage] {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try (0..<count).map { index in
            context.setFillColor(CGColor(red: varyingColors ? CGFloat(index) / CGFloat(count) : 0.2,
                                        green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            return try library.addImage(XCTUnwrap(context.makeImage()), source: "截图")
        }
    }

    private func externalImages(from images: [VaultImage], in library: LibraryStore) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ExternalSources.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try images.enumerated().map { index, image in
            let url = directory.appendingPathComponent("Input_\(index).png")
            try FileManager.default.copyItem(at: library.imageURL(image), to: url)
            return url
        }
    }

    private func addVideos(to library: LibraryStore) throws -> [URL] {
        let urls = try (0..<2).map { index in
            let directory = library.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording.mp4")
            try Data([UInt8(index + 1)]).write(to: url)
            return url
        }
        try library.reloadSessions()
        return urls
    }

    private func corruptSession(in root: URL) throws -> SavedSession {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("corrupt PNG".utf8).write(to: directory.appendingPathComponent("frame.png"))
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 1, sampleRate: 2,
                                        threshold: 0.025, width: 8, height: 6,
                                        frames: [.init(file: "frame.png", time: 0)])
        return SavedSession(id: manifest.id, directory: directory, manifest: manifest)
    }
}
