import AppKit
import XCTest
@testable import Clipato

@MainActor
final class CollectionOrganizationTests: XCTestCase {
    func testOneImageCanBelongToTwoCollectionsWithoutDuplicatingMedia() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let image = try library.addImage(fixture(), source: "截图")
        let first = try library.createCollection(name: "项目")
        let second = try library.createCollection(name: "参考")
        let originalURL = library.imageURL(image)
        let originalBytes = try Data(contentsOf: originalURL)

        try library.addToCollection(first.id, assets: [.image(image.id)])
        try library.addToCollection(second.id, assets: [.image(image.id)])
        try library.addToCollection(first.id, assets: [.image(image.id)])

        XCTAssertEqual(library.collections(containing: .image(image.id)).map(\.id), [first.id, second.id])
        XCTAssertEqual(library.images, [image])
        XCTAssertEqual(try Data(contentsOf: originalURL), originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Images").path), [image.id.uuidString])
        let reopened = try LibraryStore(root: root)
        XCTAssertEqual(reopened.collections(containing: .image(image.id)).map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.imageURL(image), originalURL)
        await library.cancelStorageWorkAndWait()
        await reopened.cancelStorageWorkAndWait()
    }

    func testUnfiledReturnsOnlyAfterLastMembershipIsRemovedOrCollectionIsDeleted() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let first = try library.addImage(fixture(), source: "截图")
        let second = try library.addImage(fixture(), source: "拼图")
        let project = try library.createCollection(name: "项目")
        let reference = try library.createCollection(name: "参考")
        let candidates: Set<CollectionAsset> = [.image(first.id), .image(second.id)]
        XCTAssertEqual(visible(candidates, filter: .unfiled, in: library), candidates)

        try library.addToCollection(project.id, assets: [.image(first.id)])
        try library.addToCollection(reference.id, assets: [.image(first.id)])
        XCTAssertEqual(visible(candidates, filter: .unfiled, in: library), [.image(second.id)])
        try library.removeFromCollection(project.id, assets: [.image(first.id)])
        XCTAssertEqual(visible(candidates, filter: .unfiled, in: library), [.image(second.id)])
        try library.removeFromCollection(reference.id, assets: [.image(first.id)])
        XCTAssertEqual(visible(candidates, filter: .unfiled, in: library), candidates)

        try library.addToCollection(project.id, assets: candidates)
        XCTAssertTrue(visible(candidates, filter: .unfiled, in: library).isEmpty)
        XCTAssertEqual(visible(candidates, filter: .all, in: library), candidates)
        try library.deleteCollection(project.id)
        XCTAssertEqual(visible(candidates, filter: .unfiled, in: library), candidates)
        XCTAssertEqual(Set(library.images.map(\.id)), [first.id, second.id])
        await library.cancelStorageWorkAndWait()
    }

    func testMembershipNamesAndOrderRefreshAfterAnotherClientEditsCollections() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let image = try library.addImage(fixture(), source: "截图")
        let first = try library.createCollection(name: "项目")
        let unrelated = try library.createCollection(name: "未加入")
        let second = try library.createCollection(name: "参考")
        try library.addToCollection(first.id, assets: [.image(image.id)])
        try library.addToCollection(second.id, assets: [.image(image.id)])
        let otherClient = try LibraryStore(root: root)

        try otherClient.renameCollection(second.id, name: "灵感")
        try otherClient.moveCollection(second.id, toParent: nil, before: first.id)
        try library.reloadImages()
        XCTAssertEqual(library.collections.map(\.id), [second.id, first.id, unrelated.id])
        XCTAssertEqual(library.collections(containing: .image(image.id)).map(\.name), ["灵感", "项目"])
        try otherClient.removeFromCollection(first.id, assets: [.image(image.id)])
        try library.reloadImages()
        XCTAssertEqual(library.collections(containing: .image(image.id)).map(\.id), [second.id])
        XCTAssertTrue(visible([.image(image.id)], filter: .unfiled, in: library).isEmpty)
        try otherClient.deleteCollection(second.id)
        try library.reloadImages()
        XCTAssertTrue(library.collections(containing: .image(image.id)).isEmpty)
        XCTAssertEqual(visible([.image(image.id)], filter: .unfiled, in: library), [.image(image.id)])

        let reopened = try LibraryStore(root: root)
        XCTAssertEqual(reopened.collections.map(\.name), ["项目", "未加入"])
        XCTAssertTrue(reopened.collections(containing: .image(image.id)).isEmpty)
        await library.cancelStorageWorkAndWait()
        await otherClient.cancelStorageWorkAndWait()
        await reopened.cancelStorageWorkAndWait()
    }

    func testImagesKeyframesAndVideosShareUnfiledRulesWithoutMovingRecordingFiles() async throws {
        let root = try temporaryDirectory()
        let library = try LibraryStore(root: root)
        let image = try library.addImage(fixture(), source: "截图")
        let sessionID = UUID()
        let sessionDirectory = root.appendingPathComponent("Sessions/\(sessionID.uuidString)")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)
        let frameURL = sessionDirectory.appendingPathComponent("frame.png")
        try LibraryStore.writePNG(fixture(), to: frameURL)
        let manifest = KeyframeManifest(id: sessionID, createdAt: Date(), duration: 1, sampleRate: 1, threshold: 0.025,
                                        width: 3, height: 2, frames: [.init(file: "frame.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: manifestURL)
        let videoDirectory = root.appendingPathComponent("Sessions/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: false)
        let videoURL = videoDirectory.appendingPathComponent("recording.mp4")
        try Data("published recording".utf8).write(to: videoURL)
        try library.reloadSessions()
        XCTAssertEqual(library.sessions.map(\.id), [sessionID])
        XCTAssertEqual(library.videos, [videoURL])
        let sourceFiles = [library.imageURL(image), frameURL, manifestURL, videoURL]
        let originalBytes = try sourceFiles.map { try Data(contentsOf: $0) }
        let assets: Set<CollectionAsset> = [.image(image.id), .session(sessionID), .video(videoURL)]
        let project = try library.createCollection(name: "项目")
        let reference = try library.createCollection(name: "参考")

        try library.addToCollection(project.id, assets: assets)
        try library.addToCollection(reference.id, assets: [.session(sessionID), .video(videoURL)])
        try library.deleteCollection(project.id)
        XCTAssertEqual(visible(assets, filter: .unfiled, in: library), [.image(image.id)])
        XCTAssertEqual(library.collections(containing: .session(sessionID)).map(\.id), [reference.id])
        XCTAssertEqual(library.collections(containing: .video(videoURL)).map(\.id), [reference.id])
        try library.removeFromCollection(reference.id, assets: [.session(sessionID)])
        XCTAssertEqual(visible(assets, filter: .unfiled, in: library), [.image(image.id), .session(sessionID)])

        let reopened = try LibraryStore(root: root)
        XCTAssertEqual(visible(assets, filter: .all, in: reopened), assets)
        XCTAssertEqual(visible(assets, filter: .unfiled, in: reopened), [.image(image.id), .session(sessionID)])
        XCTAssertEqual(reopened.collections(containing: .video(videoURL)).map(\.id), [reference.id])
        XCTAssertEqual(try sourceFiles.map { try Data(contentsOf: $0) }, originalBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sessions").path).count, 2)
        await library.cancelStorageWorkAndWait()
        await reopened.cancelStorageWorkAndWait()
    }

    private func visible(_ assets: Set<CollectionAsset>, filter: CollectionFilter, in library: LibraryStore) -> Set<CollectionAsset> {
        let collected = library.collectionMembers.values.reduce(into: Set<CollectionAsset>()) { $0.formUnion($1) }
        return assets.filter { filter.includes($0, collectedAssets: collected) }
    }

    private func fixture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.8, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-CollectionOrganizationTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
