import Combine
import XCTest
@testable import Clipato

@MainActor
final class AppModelExportTests: XCTestCase {
    func testFailedKeyframeImportReleasesExportAndKeepsCurrentSection() async throws {
        let model = try makeModel()
        model.section = .recordings
        let session = try corruptSession(in: model.libraryRoot)
        let completed = expectation(description: "Failed export finishes")
        let subscription = model.$exportingSessionID.dropFirst().filter { $0 == nil }.sink { _ in completed.fulfill() }
        defer { subscription.cancel() }

        model.exportSessionToVault(session)
        XCTAssertTrue(model.isExporting)
        XCTAssertTrue(model.exportIsIndeterminate)
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertFalse(model.isExporting)
        XCTAssertFalse(model.exportIsIndeterminate)
        XCTAssertEqual(model.section, .recordings)
        XCTAssertTrue(try XCTUnwrap(model.library).images.isEmpty)
        let frameError = KeyframeExportError.invalidFrame(session.directory.appendingPathComponent("frame.png"))
        XCTAssertEqual(model.errorMessage, L("导出到保管箱失败：\(frameError.localizedDescription)"))
        XCTAssertEqual(try Data(contentsOf: session.directory.appendingPathComponent("frame.png")), Data("corrupt PNG".utf8))
    }

    func testQuitCancellationWaitsForKeyframeImportCleanupAndRejectsSecondExport() async throws {
        let model = try makeModel()
        let first = try corruptSession(in: model.libraryRoot)
        let second = try corruptSession(in: model.libraryRoot)
        model.exportSessionToVault(first)
        model.exportSessionToVault(second)
        XCTAssertEqual(model.exportingSessionID, first.id)

        await model.cancelExportAndWait()

        XCTAssertFalse(model.isExporting)
        XCTAssertNil(model.exportingSessionID)
        XCTAssertFalse(model.exportIsIndeterminate)
        XCTAssertTrue(try XCTUnwrap(model.library).images.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.notice, L("已取消导出"))
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.AppModelExportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        XCTAssertNil(model.errorMessage)
        return model
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
