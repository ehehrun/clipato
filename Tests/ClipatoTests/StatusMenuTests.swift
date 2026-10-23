import AppKit
import CSQLite
import XCTest
@testable import Clipato

@MainActor
final class StatusMenuTests: XCTestCase {
    func testStatusMenuStartsWithCaptureAndEndsWithConsoleBesideQuit() async throws {
        let application = NSApplication.shared
        let windowCount = application.windows.count
        let model = try await makeModel()
        let delegate = ClipatoDelegate(model: model)

        let menu = delegate.installStatusMenu()
        delegate.menuWillOpen(menu)

        XCTAssertTrue(menu.delegate === delegate)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.first?.action, NSSelectorFromString("captureRegion"))
        XCTAssertFalse(try XCTUnwrap(menu.items.first).isSeparatorItem)
        XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("showAbout") })
        XCTAssertFalse(menu.items.contains { $0.action == NSSelectorFromString("checkForUpdates") })
        let recording = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("toggleRecording") })
        for mode in RecordingMode.allCases {
            model.recordingMode = mode
            delegate.menuWillOpen(menu)
            let shortcut = model.shortcuts.bindings[.toggleRecording]
            XCTAssertEqual(recording.title, L("区域录屏") + (shortcut.map { "    " + $0.displayName } ?? ""))
        }
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("selectRecordingMode:")))
        let tail = Array(menu.items.suffix(4))
        XCTAssertEqual(tail.count, 4)
        XCTAssertEqual(tail[0].title, L("清空操作历史"))
        XCTAssertTrue(tail[1].isSeparatorItem)
        XCTAssertEqual(tail[2].title, L("控制台"))
        XCTAssertEqual(tail[2].action, NSSelectorFromString("showWindow"))
        XCTAssertEqual(tail[3].title, L("退出 Clipato"))
        XCTAssertEqual(tail[3].action, NSSelectorFromString("quit"))
        XCTAssertTrue(tail[2].target === delegate)
        XCTAssertTrue(tail[3].target === delegate)
        try assertClearHistoryAction(in: menu, target: delegate)
        assertRemovedEntriesAreAbsent(from: menu)
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("importImages")))
        XCTAssertFalse(delegate.responds(to: NSSelectorFromString("showGeneralSettings")))
        XCTAssertEqual(application.windows.count, windowCount)
    }

    func testNativeAppAndFileMenusUseTheSameActionsWithoutSettingsOrImportEntries() async throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }
        let windowCount = application.windows.count
        let delegate = try await makeDelegate()

        let menu = delegate.installMainMenu()

        XCTAssertTrue(application.mainMenu === menu)
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(appMenu.items.map(\.title), [L("关于 Clipato…"), L("检查更新…"), "", L("清空操作历史"), L("快捷键设置…"), "", L("控制台"), L("退出 Clipato")])
        XCTAssertEqual(appMenu.items[0].action, NSSelectorFromString("showAbout"))
        XCTAssertEqual(appMenu.items[1].action, NSSelectorFromString("checkForUpdates"))
        XCTAssertTrue(appMenu.items[5].isSeparatorItem)
        let console = appMenu.items[6]
        XCTAssertEqual(console.action, NSSelectorFromString("showWindow"))
        XCTAssertTrue(console.target === delegate)
        let quit = try XCTUnwrap(appMenu.items.last)
        XCTAssertEqual(quit.action, NSSelectorFromString("quit"))
        XCTAssertEqual(quit.keyEquivalent, "q")
        XCTAssertEqual(quit.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quit.target === delegate)
        try assertClearHistoryAction(in: appMenu, target: delegate)
        let fileMenu = try XCTUnwrap(menu.items.first { $0.title == L("文件") }?.submenu)
        XCTAssertEqual(fileMenu.items.filter { $0.action == #selector(NSWindow.performClose(_:)) }.count, 1)
        let close = try XCTUnwrap(fileMenu.items.first)
        XCTAssertEqual(close.title, L("关闭窗口"))
        XCTAssertEqual(close.action, #selector(NSWindow.performClose(_:)))
        XCTAssertEqual(close.keyEquivalent, "w")
        let editMenu = try XCTUnwrap(menu.items.first { $0.title == L("编辑") }?.submenu)
        let selectAll = try XCTUnwrap(editMenu.items.first { $0.action == #selector(NSText.selectAll(_:)) })
        XCTAssertEqual(selectAll.title, L("全选"))
        XCTAssertEqual(selectAll.keyEquivalent, "a")
        XCTAssertEqual(selectAll.keyEquivalentModifierMask, [.command])
        XCTAssertNil(selectAll.target, "The responder chain must let a focused search field select text before selecting media.")
        assertRemovedEntriesAreAbsent(from: menu)
        XCTAssertEqual(application.windows.count, windowCount)
    }

    func testPinnedPassthroughMenuCanRestoreMouseInteractionWithoutAWorkingShortcut() async throws {
        let application = NSApplication.shared
        let model = try await makeModel()
        let delegate = ClipatoDelegate(model: model)
        let menu = delegate.installStatusMenu()
        let item = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("togglePinnedMousePassthrough") })
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(item.target === delegate)
        let panel = model.screenshots.pin(image: try pixels(), frame: CGRect(x: -10_000, y: -10_000, width: 120, height: 80))
        defer { panel.close() }
        model.shortcuts.setEnabled(false)
        try model.shortcuts.setShortcut(nil, for: .togglePinnedMousePassthrough)
        delegate.menuWillOpen(menu)
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.title, L("贴图鼠标穿透"))

        XCTAssertTrue(application.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))

        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(item.isEnabled, "A disabled or unbound global shortcut must not remove the recovery action.")
        XCTAssertTrue(application.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(item.state, .off)

        model.screenshots.togglePinnedMousePassthrough()
        panel.close()
        delegate.menuWillOpen(menu)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.state, .off)
    }

    func testRecentImageItemIsDisabledWhenEmptyAndImmediatelyAfterItsClearHistoryAction() async throws {
        let application = NSApplication.shared
        let windowCount = application.windows.count
        let model = try await makeModel()
        let library = try XCTUnwrap(model.library)
        let delegate = ClipatoDelegate(model: model)
        let menu = delegate.installStatusMenu()
        let recent = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("pinLatest") })
        XCTAssertFalse(recent.isEnabled)
        let image = try library.addImage(pixels(), source: "截图", filename: "remembered.png")
        delegate.menuWillOpen(menu)
        XCTAssertTrue(recent.isEnabled)
        let clear = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("clearOperationHistory") })

        XCTAssertTrue(application.sendAction(try XCTUnwrap(clear.action), to: clear.target, from: clear))

        XCTAssertFalse(recent.isEnabled, "The same menu item must update before the menu opens again.")
        XCTAssertEqual(library.images, [image])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(image).path))
        XCTAssertNil(model.errorMessage)
        model.pinLatest()
        XCTAssertNil(model.errorMessage, "The shortcut should quietly do nothing after its memory is cleared.")
        XCTAssertEqual(application.windows.count, windowCount)
        await library.cancelStorageWorkAndWait()
    }

    func testClearedStateSurvivesANewDelegateAndNewImagesOrImportsEnableTheItemAgain() async throws {
        _ = NSApplication.shared
        let original = try await makeModel()
        let originalLibrary = try XCTUnwrap(original.library)
        _ = try originalLibrary.addImage(pixels(), source: "截图", filename: "retained.png")
        try originalLibrary.clearOperationHistory()
        let reopened = try await makeModel(root: original.libraryRoot)
        let library = try XCTUnwrap(reopened.library)
        let delegate = ClipatoDelegate(model: reopened)
        let menu = delegate.installStatusMenu()
        let recent = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("pinLatest") })
        XCTAssertFalse(recent.isEnabled)
        XCTAssertEqual(library.images.count, 1)

        _ = try library.addImage(pixels(), source: "截图", filename: "fresh.png")
        delegate.menuWillOpen(menu)
        XCTAssertTrue(recent.isEnabled)
        try library.clearOperationHistory()
        delegate.menuWillOpen(menu)
        XCTAssertFalse(recent.isEnabled)
        let external = original.libraryRoot.appendingPathComponent("imported.png")
        try LibraryStore.writePNG(pixels(), to: external)
        try library.importImages([external])
        delegate.menuWillOpen(menu)
        XCTAssertTrue(recent.isEnabled)
        XCTAssertEqual(library.images.count, 3)
        await originalLibrary.cancelStorageWorkAndWait()
        await library.cancelStorageWorkAndWait()
    }

    func testMenuRefreshReadsOtherConnectionsAndDoesNotFallBackAfterRememberedImageIsDeleted() async throws {
        _ = NSApplication.shared
        let model = try await makeModel()
        let library = try XCTUnwrap(model.library)
        let older = try library.addImage(pixels(), source: "截图", filename: "older.png")
        let latest = try library.addImage(pixels(), source: "截图", filename: "latest.png")
        let delegate = ClipatoDelegate(model: model)
        let menu = delegate.installStatusMenu()
        let recent = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("pinLatest") })
        XCTAssertTrue(recent.isEnabled)
        let writer = try LibraryStore(root: library.root)

        try writer.clearOperationHistory()
        delegate.menuWillOpen(menu)
        XCTAssertFalse(recent.isEnabled)
        try writer.rememberImage(older.id)
        delegate.menuWillOpen(menu)
        XCTAssertTrue(recent.isEnabled)
        try writer.rememberImage(latest.id)
        let database = try LibraryDatabase(root: library.root)
        try database.delete(latest.id)
        delegate.menuWillOpen(menu)
        XCTAssertFalse(recent.isEnabled)
        XCTAssertEqual(library.images, [older])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.imageURL(older).path))
        XCTAssertNil(model.errorMessage)
        await writer.cancelStorageWorkAndWait()
        await library.cancelStorageWorkAndWait()
    }

    func testDatabaseReadFailureDisablesTheItemAndKeepsTheActualDiagnostic() async throws {
        _ = NSApplication.shared
        let model = try await makeModel()
        let library = try XCTUnwrap(model.library)
        _ = try library.addImage(pixels(), source: "截图")
        let delegate = ClipatoDelegate(model: model)
        let menu = delegate.installStatusMenu()
        let recent = try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString("pinLatest") })
        XCTAssertTrue(recent.isEnabled)
        await library.cancelStorageWorkAndWait()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(library.root.appendingPathComponent("library.sqlite").path, &connection), SQLITE_OK)
        let database = try XCTUnwrap(connection)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "DROP TABLE operationHistory", nil, nil, nil), SQLITE_OK,
                       String(cString: sqlite3_errmsg(database)))

        delegate.menuWillOpen(menu)

        XCTAssertFalse(recent.isEnabled)
        let diagnostic = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(diagnostic.contains("operationHistory"), diagnostic)
        XCTAssertFalse(diagnostic.isEmpty)
        await library.cancelStorageWorkAndWait()
    }

    private func assertClearHistoryAction(in menu: NSMenu, target: ClipatoDelegate) throws {
        let items = menu.items.filter { $0.action == NSSelectorFromString("clearOperationHistory") }
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.title, L("清空操作历史"))
        XCTAssertTrue(item.target === target)
        XCTAssertTrue(target.responds(to: try XCTUnwrap(item.action)))
    }

    private func assertRemovedEntriesAreAbsent(from menu: NSMenu) {
        for item in menu.items {
            XCTAssertNotEqual(item.title, L("通用设置…"))
            XCTAssertNotEqual(item.title, L("导入图片…"))
            XCTAssertNotEqual(item.title, L("录屏模式"))
            XCTAssertNotEqual(item.action, NSSelectorFromString("selectRecordingMode:"))
            XCTAssertNotEqual(item.action, NSSelectorFromString("showGeneralSettings"))
            XCTAssertNotEqual(item.action, NSSelectorFromString("importImages"))
            if let submenu = item.submenu { assertRemovedEntriesAreAbsent(from: submenu) }
        }
    }

    private func makeDelegate() async throws -> ClipatoDelegate {
        ClipatoDelegate(model: try await makeModel())
    }

    private func makeModel(root existingRoot: URL? = nil) async throws -> AppModel {
        let root = existingRoot ?? FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.StatusMenu.\(UUID().uuidString)")
        let name = "Clipato.StatusMenu.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            if existingRoot == nil { try FileManager.default.removeItem(at: root) }
        }
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        let library = try XCTUnwrap(model.library, model.errorMessage ?? "Test library could not be opened.")
        await library.cancelStorageWorkAndWait()
        return model
    }

    private func pixels() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return try XCTUnwrap(context.makeImage())
    }
}
