import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CollectionDragTests: XCTestCase {
    func testDraggingMultipleImagesAddsReferencesWithoutDuplicatingFiles() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let first = try library.addImage(fixture(red: 0.9), source: "截图")
        let second = try library.addImage(fixture(red: 0.2), source: "拼图")
        let folder = try library.createCollection(name: "项目素材")
        let originalImages = library.images
        let originalBytes = try originalImages.map { try Data(contentsOf: library.imageURL($0)) }
        let imageDirectories = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).sorted()
        let assets: Set<CollectionAsset> = [.image(first.id), .image(second.id)]
        let provider = CollectionDrag.provider(assets: assets)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(CollectionDrag.assetType.identifier))

        for _ in 0..<2 {
            let decoded = try await loadAssets(provider)
            XCTAssertEqual(decoded, assets)
            try library.addToCollection(folder.id, assets: decoded)
        }

        XCTAssertEqual(library.collectionMembers[folder.id], assets)
        XCTAssertEqual(try LibraryDatabase(root: root).collectionState().1[folder.id], assets)
        XCTAssertEqual(library.images, originalImages)
        XCTAssertEqual(try originalImages.map { try Data(contentsOf: library.imageURL($0)) }, originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path).sorted(), imageDirectories)
        await library.cancelStorageWorkAndWait()
    }

    func testMalformedDragDataReportsErrorWithoutCreatingMembership() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let item = try library.addImage(fixture(red: 0.4), source: "截图")
        let original = try Data(contentsOf: library.imageURL(item))
        let folder = try library.createCollection(name: "素材")
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: CollectionDrag.assetType.identifier, visibility: .ownProcess) { completion in
            completion(Data("[{ broken payload".utf8), nil)
            return nil
        }

        do {
            let assets = try await loadAssets(provider)
            try library.addToCollection(folder.id, assets: assets)
            XCTFail("畸形拖动数据不应被接受")
        } catch {
            XCTAssertTrue(error is DecodingError, error.localizedDescription)
        }

        XCTAssertEqual(library.collectionMembers[folder.id], [])
        XCTAssertEqual(try LibraryDatabase(root: root).collectionState().1[folder.id], [])
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), original)
        await library.cancelStorageWorkAndWait()
    }

    func testDropIntoFolderDeletedAfterDragStartsFailsWithoutChangingImages() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let item = try library.addImage(fixture(red: 0.6), source: "截图")
        let original = try Data(contentsOf: library.imageURL(item))
        let folder = try library.createCollection(name: "临时项目")
        let provider = CollectionDrag.provider(assets: [.image(item.id)])
        try LibraryDatabase(root: root).deleteCollection(folder.id)

        let assets = try await loadAssets(provider)
        XCTAssertThrowsError(try library.addToCollection(folder.id, assets: assets)) { error in
            guard case CollectionError.missingCollection = error else {
                return XCTFail("应明确报告目标已删除：\(error)")
            }
        }

        XCTAssertTrue(library.collections.isEmpty)
        XCTAssertTrue(library.collectionMembers.isEmpty)
        XCTAssertTrue(try LibraryDatabase(root: root).collectionState().1.isEmpty)
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path), [item.id.uuidString])
        await library.cancelStorageWorkAndWait()
    }

    func testCollectionProviderRoundTripsFolderIdentity() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let parent = try library.createCollection(name: "工作")
        let child = try library.createCollection(name: "项目 A")
        let provider = CollectionDrag.provider(collection: child)
        XCTAssertEqual(provider.suggestedName, child.name)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(CollectionDrag.folderType.identifier))

        let id: UUID = try await withCheckedThrowingContinuation { continuation in
            CollectionDrag.loadCollection(from: provider) { continuation.resume(with: $0) }
        }

        XCTAssertEqual(id, child.id)
        try library.moveCollection(id, toParent: nil, before: parent.id)
        XCTAssertEqual(library.collections.map(\.id), [child.id, parent.id])
        XCTAssertNil(library.collections.first?.parentID)
        await library.cancelStorageWorkAndWait()
    }

    private func loadAssets(_ provider: NSItemProvider) async throws -> Set<CollectionAsset> {
        try await withCheckedThrowingContinuation { continuation in
            CollectionDrag.loadAssets(from: provider) { continuation.resume(with: $0) }
        }
    }

    private func fixture(red: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CollectionDragTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
