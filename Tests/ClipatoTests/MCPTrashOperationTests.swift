import AppKit
import XCTest
@testable import Clipato

@MainActor
final class MCPTrashOperationTests: XCTestCase {
    func testRevocationDuringRealTrashMoveStopsTheRemainingBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-TrashRevocation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Clipato.TrashRevocationTests.\(UUID())"
        nonisolated(unsafe) let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
        MCPSettings.setEnabled(true, in: defaults)
        defaults.set(true, forKey: MCPSettings.allowTrashKey)
        let trash = root.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let store = try LibraryStore(root: root.appendingPathComponent("vault"), defaults: defaults, trashImageDirectory: { source in
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            MCPSettings.setEnabled(false, in: defaults)
            return target
        })
        let first = try addImage(store)
        let second = try addImage(store)
        let firstURL = store.imageURL(first)
        let original = try Data(contentsOf: firstURL)
        do {
            _ = try await AutomationAccess.$current.withValue(AutomationAccess(defaults: defaults)) {
                try await MCPTrashOperation.perform(assets: [.image(first.id), .image(second.id)], store: store,
                    isAllowed: { MCPSettings.allowsTrash(in: defaults) }, confirm: { _ in true })
            }
            XCTFail("Revocation must stop before moving the next asset")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Moved 1 of 2 items to Trash before failure"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(try Data(contentsOf: trash.appendingPathComponent(firstURL.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(firstURL.lastPathComponent)), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(second).path))
        XCTAssertEqual(store.images.map(\.id), [second.id])
        await store.cancelStorageWorkAndWait()
    }

    func testPartialMoveFailureReportsCompletedCountAndPreservesRemainingFile() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try addImage(store)
        let second = try addImage(store)
        let collision = root.appendingPathComponent("TestTrash").appendingPathComponent(store.imageURL(second).deletingLastPathComponent().lastPathComponent)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: false)
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(first.id), .image(second.id)], store: store,
                                                    isAllowed: { true }, confirm: { _ in true })
            XCTFail("A failed move must be reported")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Moved 1 of 2 items to Trash before failure")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(first).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(second).path))
        XCTAssertEqual(store.images.map(\.id), [second.id])
        await store.cancelStorageWorkAndWait()
    }

    func testDisabledPermissionAndRejectedConfirmationKeepFilesAndCollections() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try addImage(store)
        let collection = try store.createCollection(name: "保留")
        try store.addToCollection(collection.id, assets: [.image(item.id)])
        let bytes = try Data(contentsOf: store.imageURL(item))
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id)], store: store, isAllowed: { false }, confirm: { _ in
                XCTFail("Disabled requests must not reach the confirmation UI")
                return true
            })
            XCTFail("Permission is required")
        } catch { XCTAssertEqual(error as? MCPTrashAuthorizationError, .disabled) }
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id)], store: store, isAllowed: { true }, confirm: { selection in
                XCTAssertEqual(selection.collectionCount, 1)
                XCTAssertEqual(selection.names, [item.filename])
                return false
            })
            XCTFail("A rejected request must not execute")
        } catch { XCTAssertEqual(error as? MCPTrashAuthorizationError, .rejected) }
        XCTAssertEqual(try Data(contentsOf: store.imageURL(item)), bytes)
        XCTAssertEqual(store.assets(in: collection.id), [.image(item.id)])
        await store.cancelStorageWorkAndWait()
    }

    func testRevokedPermissionAndChangedContentInvalidateApproval() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try addImage(store)
        var allowed = true
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id)], store: store, isAllowed: { allowed }, confirm: { _ in
                allowed = false
                return true
            })
            XCTFail("A revoked permission must be checked again after confirmation")
        } catch { XCTAssertEqual(error as? MCPTrashAuthorizationError, .disabled) }
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id)], store: store, isAllowed: { true }, confirm: { _ in
                try Data("changed after preview".utf8).write(to: store.imageURL(item))
                return true
            })
            XCTFail("Approval only applies to the content the user saw")
        } catch { XCTAssertEqual(error as? MCPTrashAuthorizationError, .selectionChanged) }
        XCTAssertEqual(store.images.map(\.id), [item.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(item).path))
        await store.cancelStorageWorkAndWait()
    }

    func testApprovedBatchMovesRealDirectoriesAndRemovesOnlyMatchingMembership() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try addImage(store)
        let second = try addImage(store)
        let collection = try store.createCollection(name: "素材")
        try store.addToCollection(collection.id, assets: [.image(first.id), .image(second.id)])
        let firstURL = store.imageURL(first)
        let bytes = try Data(contentsOf: firstURL)
        let result = try await MCPTrashOperation.perform(assets: [.image(first.id), .image(first.id)], store: store,
                                                        isAllowed: { true }, confirm: { selection in
            XCTAssertEqual(selection.assets, [.image(first.id)])
            return true
        })
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let moved = root.appendingPathComponent("TestTrash").appendingPathComponent(firstURL.deletingLastPathComponent().lastPathComponent)
            .appendingPathComponent(firstURL.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: moved), bytes)
        XCTAssertEqual(store.images.map(\.id), [second.id])
        XCTAssertEqual(store.assets(in: collection.id), [.image(second.id)])
        await store.cancelStorageWorkAndWait()
    }

    func testUnknownAssetAndCancellationLeaveEntireBatchUntouched() async throws {
        let (store, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try addImage(store)
        let external = root.appendingPathComponent("external.mp4")
        try Data("external".utf8).write(to: external)
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id), .video(external)], store: store,
                                                    isAllowed: { true }, confirm: { _ in
                XCTFail("Validate all assets before asking for approval")
                return true
            })
            XCTFail("External files are not vault assets")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not in this vault")) }
        do {
            _ = try await MCPTrashOperation.perform(assets: [.image(item.id)], store: store, isAllowed: { true }, confirm: { _ in
                throw CancellationError()
            })
            XCTFail("Cancellation must not execute the batch")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(item).path))
        XCTAssertEqual(try String(contentsOf: external), "external")
        await store.cancelStorageWorkAndWait()
    }

    private func fixture() throws -> (LibraryStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-MCP-Trash-\(UUID())")
        let trash = root.appendingPathComponent("TestTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let suite = "Clipato.MCPTrashTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = try LibraryStore(root: root.appendingPathComponent("vault"), defaults: defaults, trashImageDirectory: { source in
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        })
        return (store, root)
    }

    private func addImage(_ store: LibraryStore) throws -> VaultImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try store.addImage(XCTUnwrap(context.makeImage()), source: "测试")
    }
}
