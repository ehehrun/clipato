import AppKit
import Combine
import XCTest
@testable import Clipato

@MainActor
final class AppModelNoticeTests: XCTestCase {
    func testClearingOperationHistoryPreservesMediaCollectionsAndCurrentWork() throws {
        let model = try makeModel()
        let library = try XCTUnwrap(model.library)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let item = try library.addImage(image, source: "截图", tag: .green)
        let collection = try library.createCollection(name: "素材", parentID: nil)
        try library.addToCollection(collection.id, assets: [.image(item.id)])
        let original = try Data(contentsOf: library.imageURL(item))
        model.selected = [item.id]
        model.query = "素材"
        model.editing = EditingImage(image: image)
        model.collage = CollageSelection(images: [image])
        let editingID = model.editing?.id
        let collageID = model.collage?.id

        model.clearOperationHistory()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.notice, L("已清空操作历史"))
        XCTAssertNil(try library.recentImage())
        XCTAssertNil(try LibraryStore(root: model.libraryRoot).recentImage())
        XCTAssertEqual(library.images, [item])
        XCTAssertEqual(library.collectionMembers[collection.id], [.image(item.id)])
        XCTAssertEqual(try Data(contentsOf: library.imageURL(item)), original)
        XCTAssertEqual(model.selected, [item.id])
        XCTAssertEqual(model.query, "素材")
        XCTAssertEqual(model.editing?.id, editingID)
        XCTAssertEqual(model.collage?.id, collageID)
        model.pinLatest()
        XCTAssertNil(model.errorMessage)
    }

    func testRepeatingSameNoticeRestartsDismissalWithoutOldTimerClearingIt() async throws {
        let model = try makeModel()
        let dismissed = expectation(description: "The repeated notice expires")
        var publications: [String?] = []
        var dismissedAt: Date?
        let subscription = model.$notice.dropFirst().sink { notice in
            publications.append(notice)
            if notice == nil {
                dismissedAt = Date()
                dismissed.fulfill()
            }
        }
        defer { subscription.cancel() }

        let message = "图片已复制"
        model.notice = message
        try await Task.sleep(nanoseconds: 1_800_000_000)
        let repeatedAt = Date()
        model.notice = message
        try await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(model.notice, message, "The original timer must not clear a newer occurrence of the same message")
        XCTAssertEqual(publications, [message, message])
        await fulfillment(of: [dismissed], timeout: 3)
        XCTAssertNil(model.notice)
        XCTAssertEqual(publications, [message, message, nil])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(dismissedAt).timeIntervalSince(repeatedAt), 2.9)
    }

    func testDismissalWorksWithoutConsoleAndManualDismissalCancelsPendingWork() async throws {
        let model = try makeModel()
        let manuallyDismissedModel = try makeModel()
        let dismissed = expectation(description: "Notice expires independently of the selected section")
        let subscription = model.$notice.dropFirst().sink { notice in
            if notice == nil { dismissed.fulfill() }
        }
        var manualPublications: [String?] = []
        let manualSubscription = manuallyDismissedModel.$notice.dropFirst().sink { manualPublications.append($0) }
        defer {
            subscription.cancel()
            manualSubscription.cancel()
        }

        model.notice = "拼图已保存到保管箱"
        model.section = .shortcuts
        model.section = .general
        manuallyDismissedModel.notice = "已导入 2 张图片"
        manuallyDismissedModel.notice = nil

        var disposableModel: AppModel? = try makeModel()
        weak var releasedModel = disposableModel
        disposableModel?.notice = "截图已保存到保管箱"
        disposableModel = nil
        XCTAssertNil(releasedModel, "A pending notice timer must not retain the model")

        await fulfillment(of: [dismissed], timeout: 4)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.section, .general)
        XCTAssertEqual(manualPublications, ["已导入 2 张图片", nil], "Manual dismissal must cancel the timer instead of publishing nil a second time")
    }

    private func makeModel() throws -> AppModel {
        let name = "Clipato.AppModelNoticeTests.\(UUID().uuidString)"
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
}
