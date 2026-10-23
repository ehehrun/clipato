import AppKit
import XCTest
@testable import Clipato

@MainActor
final class BatchRenameWorkflowTests: XCTestCase {
    func testImageRenameUsesSelectionOrderAndClosesOnlyAfterSuccess() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let first = try library.addImage(pixels(), source: "截图")
        let second = try library.addImage(pixels(), source: "截图")
        let assets = [CollectionAsset.image(second.id), .image(first.id)]
        model.prepareBatchRename(assets)
        XCTAssertEqual(model.batchRenameAssets, assets)

        try model.batchRename(rule: BatchRenameRule(prefix: "Order_", start: 7, increment: 2, digits: 2))

        let byID = Dictionary(uniqueKeysWithValues: library.images.map { ($0.id, $0.filename) })
        XCTAssertEqual(byID[second.id], "Order_07.png")
        XCTAssertEqual(byID[first.id], "Order_09.png")
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
        XCTAssertEqual(model.batchRenameChanges, Dictionary(uniqueKeysWithValues: assets.map { ($0, $0) }))
    }

    func testInvalidRuleKeepsTheSelectionAvailableForCorrection() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let first = try library.addImage(pixels(), source: "截图")
        let second = try library.addImage(pixels(), source: "截图")
        let assets = [CollectionAsset.image(first.id), .image(second.id)]
        model.prepareBatchRename(assets)

        XCTAssertThrowsError(try model.batchRename(rule: BatchRenameRule(prefix: "Frame_", start: 1, increment: 0, digits: 3)))

        XCTAssertEqual(model.batchRenameAssets, assets)
        XCTAssertTrue(model.batchRenameChanges.isEmpty)
        XCTAssertEqual(library.images.first(where: { $0.id == first.id })?.filename, first.filename)
        XCTAssertEqual(library.images.first(where: { $0.id == second.id })?.filename, second.filename)
    }

    func testVideoRenamePublishesNewIdentitiesForRetainingSelection() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let urls = try (0..<2).map { index -> URL in
            let directory = library.root.appendingPathComponent("Sessions").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("recording.mp4")
            try Data([UInt8(index + 1)]).write(to: url)
            return url
        }
        try library.reloadSessions()
        model.prepareBatchRename(urls.map(CollectionAsset.video))

        try model.batchRename(rule: BatchRenameRule(prefix: "Clip_", start: 1, increment: 1, digits: 2))

        for (index, url) in urls.enumerated() {
            let destination = url.deletingLastPathComponent().appendingPathComponent("Clip_0\(index + 1).mp4")
            XCTAssertEqual(model.batchRenameChanges[.video(url)], .video(destination))
            XCTAssertTrue(library.videos.contains(destination))
        }
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.BatchRenameWorkflow.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        return AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults))
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
