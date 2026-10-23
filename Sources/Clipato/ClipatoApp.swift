import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let clipatoSelectAllVisibleAssets = Notification.Name("ClipatoSelectAllVisibleAssets")
    static let clipatoPreviewSelectedImage = Notification.Name("ClipatoPreviewSelectedImage")
    static let clipatoShowCollageWorkspace = Notification.Name("ClipatoShowCollageWorkspace")
    static let clipatoShowScreenCapturePermissions = Notification.Name("ClipatoShowScreenCapturePermissions")
}

@MainActor
enum ClipatoApp {
    static func startCommandEventLoop() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.appearance = AppTheme.saved.appearance
        // AppKit must enter outside a dispatch callback so async capture work can use the main queue.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { application.run() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.appearance = AppTheme.saved.appearance
        let delegate = ClipatoDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class ClipatoDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private var subscriptions = Set<AnyCancellable>()
    private var shortcutMenuItems: [ShortcutAction: NSMenuItem] = [:]
    private var pauseRecordingItem: NSMenuItem?
    private var disableShortcutsItem: NSMenuItem?
    private var mainWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var longScreenshotWindow: NSWindow?
    private var shortcutSettingsWindow: NSWindow?
    private var isPresentingError = false

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    override convenience init() {
        self.init(model: AppModel())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem
        statusItem.button?.image = ClipatoBrand.mark
        statusItem.button?.setAccessibilityLabel("Clipato")
        statusItem.button?.toolTip = L("Clipato · 截图与录屏")
        installStatusMenu()
        model.recorder.$isRecording.combineLatest(model.recorder.$isPaused).receive(on: RunLoop.main).sink { [weak self] recording, paused in
            self?.statusItem?.button?.image = recording
                ? NSImage(systemSymbolName: paused ? "pause.circle.fill" : "record.circle.fill", accessibilityDescription: nil)
                : ClipatoBrand.mark
            self?.statusItem?.button?.setAccessibilityLabel(recording ? (paused ? L("录屏已暂停") : L("正在录屏")) : "Clipato")
            self?.statusItem?.button?.contentTintColor = recording ? (paused ? .systemOrange : .systemRed) : nil
            self?.updateShortcutMenuItems()
        }.store(in: &subscriptions)
        model.shortcuts.objectWillChange.receive(on: RunLoop.main).sink { [weak self] in
            self?.updateShortcutMenuItems()
            if let self { self.model.fixedCaptureOverlay.updateShortcutDescription(self.model.fixedCaptureShortcutDescription) }
        }.store(in: &subscriptions)
        model.screenshots.$pinnedMousePassthrough.combineLatest(model.screenshots.$hasPinnedImages)
            .receive(on: RunLoop.main).sink { [weak self] _, _ in
                self?.updateShortcutMenuItems()
            }.store(in: &subscriptions)
        model.$selectingRecordingRegion.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShortcutMenuItems()
        }.store(in: &subscriptions)
        model.$recordingBusy.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShortcutMenuItems()
        }.store(in: &subscriptions)
        model.$fixedCaptureRegion.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShortcutMenuItems()
        }.store(in: &subscriptions)
        model.$capturing.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShortcutMenuItems()
        }.store(in: &subscriptions)
        model.$clearingLibraryData.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShortcutMenuItems()
            self?.updateRecentImageMenuItem()
        }.store(in: &subscriptions)
        model.$longScreenshot.receive(on: RunLoop.main).sink { [weak self] item in
            self?.showLongScreenshot(item)
        }.store(in: &subscriptions)
        model.$collage.receive(on: RunLoop.main).sink { [weak self] item in
            self?.showCollage(item)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .clipatoShowCollageWorkspace, object: model)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.bringCollageWorkspaceForward()
            }.store(in: &subscriptions)
        model.$editing.receive(on: RunLoop.main).sink { [weak self] item in
            self?.showEditor(item)
        }.store(in: &subscriptions)
        model.$errorMessage.compactMap { $0 }.receive(on: RunLoop.main).sink { [weak self] message in
            self?.presentError(message)
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .clipatoShowScreenCapturePermissions, object: model)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.showConsoleWindow()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .clipatoAppearanceDidChange, object: AppearanceSettings.shared)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.mainWindow?.backgroundColor = NSColor(Palette.background)
                self?.longScreenshotWindow?.backgroundColor = NSColor(Palette.background)
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .clipatoLanguageDidChange)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.updateLanguage()
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main).sink { _ in
                if LanguageSettings.shared.language == .system { LanguageSettings.shared.setLanguage(.system) }
            }.store(in: &subscriptions)
        model.shortcuts.start(actions: [
            .captureRegion: { [weak model] in model?.capture(region: true) },
            .captureDisplay: { [weak model] in model?.capture(region: false) },
            .pinLatest: { [weak model] in model?.pinLatest() },
            .toggleRecording: { [weak model] in model?.toggleRecording() },
            .fixedCapture: { [weak model] in model?.captureFixedRegion() },
            .togglePinnedMousePassthrough: { [weak model] in model?.screenshots.togglePinnedMousePassthrough() }
        ])
        updateShortcutMenuItems()
        DispatchQueue.main.async { [weak model] in
            guard let model, !model.capturing, !model.recordingBusy, !model.selectingRecordingRegion else { return }
            SelectionView.prepareInterface()
        }
    }

    @discardableResult
    func installStatusMenu() -> NSMenu {
        shortcutMenuItems.removeAll(keepingCapacity: true)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        shortcutMenuItems[.captureRegion] = add(L("截取区域"), action: #selector(captureRegion), to: menu)
        shortcutMenuItems[.fixedCapture] = add(L("固定区域连续截图"), action: #selector(captureFixedRegion), to: menu)
        shortcutMenuItems[.captureDisplay] = add(L("截取当前屏幕"), action: #selector(captureDisplay), to: menu)
        shortcutMenuItems[.pinLatest] = add(L("贴出最近图片"), action: #selector(pinLatest), to: menu)
        shortcutMenuItems[.togglePinnedMousePassthrough] = add(L("贴图鼠标穿透"), action: #selector(togglePinnedMousePassthrough), to: menu)
        menu.addItem(.separator())
        shortcutMenuItems[.toggleRecording] = add(L("区域录屏"), action: #selector(toggleRecording), to: menu)
        pauseRecordingItem = add(L("暂停录屏"), action: #selector(toggleRecordingPause), to: menu)
        menu.addItem(.separator())
        add(L("快捷键设置…"), action: #selector(showShortcutSettings), to: menu)
        disableShortcutsItem = add(L("禁用快捷键"), action: #selector(toggleShortcuts), to: menu)
        menu.addItem(.separator())
        add(L("清空操作历史"), action: #selector(clearOperationHistory), to: menu)
        menu.addItem(.separator())
        add(L("控制台"), action: #selector(showWindow), to: menu)
        add(L("退出 Clipato"), action: #selector(quit), to: menu)
        statusItem?.menu = menu
        updateShortcutMenuItems()
        updateRecentImageMenuItem()
        return menu
    }

    private func updateLanguage() {
        installMainMenu()
        installStatusMenu()
        updateShortcutMenuItems()
        model.fixedCaptureOverlay.updateShortcutDescription(model.fixedCaptureShortcutDescription)
        statusItem?.button?.toolTip = L("Clipato · 截图与录屏")
        statusItem?.button?.setAccessibilityLabel(model.recorder.isRecording
            ? (model.recorder.isPaused ? L("录屏已暂停") : L("正在录屏")) : "Clipato")
        editorWindow?.title = L("Clipato · 截图标注")
        longScreenshotWindow?.title = L("Clipato · 拼图工作台")
        shortcutSettingsWindow?.title = L("Clipato · 快捷键设置")
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateShortcutMenuItems()
        updateRecentImageMenuItem()
    }

    private func updateRecentImageMenuItem() {
        guard !model.clearingLibraryData else {
            shortcutMenuItems[.pinLatest]?.isEnabled = false
            return
        }
        do {
            shortcutMenuItems[.pinLatest]?.isEnabled = try model.library?.recentImage() != nil
        } catch {
            shortcutMenuItems[.pinLatest]?.isEnabled = false
            model.errorMessage = error.localizedDescription
        }
    }

    private func updateShortcutMenuItems() {
        for (action, item) in shortcutMenuItems {
            let title = action == .toggleRecording
                ? (model.recorder.isRecording ? L("停止并保存录屏") : (model.selectingRecordingRegion ? L("正在框选录屏区域…") : L("区域录屏")))
                : (action == .fixedCapture && model.fixedCaptureRegion != nil ? L("固定区域再截一张") : action.title)
            if let shortcut = model.shortcuts.bindings[action] {
                item.title = "\(title)    \(shortcut.displayName)"
            } else {
                item.title = title
            }
        }
        disableShortcutsItem?.state = model.shortcuts.isEnabled ? .off : .on
        shortcutMenuItems[.togglePinnedMousePassthrough]?.state = model.screenshots.pinnedMousePassthrough ? .on : .off
        shortcutMenuItems[.togglePinnedMousePassthrough]?.isEnabled = model.screenshots.hasPinnedImages
        pauseRecordingItem?.title = model.recorder.isPaused ? L("继续录屏") : L("暂停录屏")
        pauseRecordingItem?.isHidden = !model.recorder.isRecording
        pauseRecordingItem?.isEnabled = model.recorder.isRecording && !model.recordingBusy
        shortcutMenuItems[.toggleRecording]?.isEnabled = !model.clearingLibraryData && !model.recordingBusy && model.fixedCaptureRegion == nil
        shortcutMenuItems[.fixedCapture]?.isEnabled = model.canCaptureFixedRegion
        for action in [ShortcutAction.captureRegion, .captureDisplay] {
            shortcutMenuItems[action]?.isEnabled = !model.clearingLibraryData && !model.capturing && !model.recordingBusy && model.fixedCaptureRegion == nil
        }
    }

    @objc func selectAll(_ sender: Any?) {
        guard canSelectAllVisibleAssets else { return }
        NotificationCenter.default.post(name: .clipatoSelectAllVisibleAssets, object: model)
    }

    private func previewSelectedImage() -> Bool {
        guard model.section == .images || model.section == .collections,
              canSelectAllVisibleAssets, !model.selected.isEmpty else { return false }
        NotificationCenter.default.post(name: .clipatoPreviewSelectedImage, object: model)
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(selectAll(_:)) || canSelectAllVisibleAssets
    }

    private var canSelectAllVisibleAssets: Bool {
        mainWindow?.isKeyWindow == true && mainWindow?.attachedSheet == nil &&
            model.library != nil && (model.section == .images ||
                model.section == .recordings ||
                (model.section == .collections && model.selectedCollectionID != nil))
    }

    @discardableResult
    func installMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Clipato", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Clipato")
        add(L("关于 Clipato…"), action: #selector(showAbout), to: appMenu)
        add(L("检查更新…"), action: #selector(checkForUpdates), to: appMenu)
        appMenu.addItem(.separator())
        add(L("清空操作历史"), action: #selector(clearOperationHistory), to: appMenu)
        add(L("快捷键设置…"), action: #selector(showShortcutSettings), to: appMenu)
        appMenu.addItem(.separator())
        add(L("控制台"), action: #selector(showWindow), to: appMenu)
        let quitItem = add(L("退出 Clipato"), action: #selector(quit), to: appMenu)
        quitItem.keyEquivalent = "q"
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem(title: L("文件"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L("文件"))
        fileMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        let editItem = NSMenuItem(title: L("编辑"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        // The responder chain lets active text fields select text before the console selects assets.
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        return menu
    }

    private func showEditor(_ item: EditingImage?) {
        guard let item else {
            editorWindow?.performClose(nil)
            return
        }
        let window: NSWindow
        if let editorWindow { window = editorWindow }
        else {
            window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 680))
            window.title = L("Clipato · 截图标注")
            window.contentMinSize = CGSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            editorWindow = window
        }
        window.contentView = NSHostingView(rootView: ImageEditorView(image: item.image, initialTag: item.tag, onSave: model.saveEdited, onPin: { [model] image in
            model.screenshots.pin(image: image)
        }, onClose: { [weak window] in window?.performClose(nil) }))
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [])
    }

    private func showLongScreenshot(_ item: LongScreenshotSelection?) {
        guard let item else { return }
        showCollageWorkspace(images: item.images, initialMode: .longScreenshot, tag: item.tag)
    }

    private func showCollage(_ item: CollageSelection?) {
        guard let item else { return }
        showCollageWorkspace(images: item.images, initialMode: .savedCollageMode, tag: item.tag)
    }

    private func showCollageWorkspace(images: [CGImage], initialMode: CollageWorkspaceMode, tag: AssetTag?) {
        if longScreenshotWindow != nil {
            bringCollageWorkspaceForward()
            return
        }
        let window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760))
        window.title = L("Clipato · 拼图工作台")
        window.contentMinSize = CGSize(width: 860, height: 620)
        window.backgroundColor = NSColor(Palette.background)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: CollageView(images: images, initialMode: initialMode, initialTag: tag,
                                                                onSave: model.saveCollage, onCopy: model.copyImage,
                                                                onChange: model.markCollageChanged,
                                                                onClose: { [weak window] in window?.performClose(nil) })
            .environment(\.consoleFontScale, 1)
            .font(.system(size: 13)))
        longScreenshotWindow = window
        window.center()
        // Make the workbench main/key before activation, so the console is not the activation target.
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [])
        updateShortcutMenuItems()
    }

    private func bringCollageWorkspaceForward() {
        guard let window = longScreenshotWindow else { return }
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [])
    }

    private func presentError(_ message: String) {
        model.errorMessage = nil
        isPresentingError = true
        defer { isPresentingError = false }
        let alert = NSAlert()
        alert.messageText = L("操作未完成")
        alert.informativeText = message
        alert.addButton(withTitle: L("知道了"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func showWindow() {
        showConsoleWindow()
    }

    func showConsoleWindow() {
        let window: NSWindow
        if let mainWindow { window = mainWindow }
        else {
            let console = ConsoleWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 790), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            console.onSpace = { [weak self] in
                guard let self else { return false }
                return self.previewSelectedImage()
            }
            console.onEscape = { [weak self] in self?.model.imageProcessingRoute != nil }
            window = console
            window.title = "Clipato"
            window.titleVisibility = .hidden
            window.backgroundColor = NSColor(Palette.background)
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = CGSize(width: 1020, height: 700)
            window.center()
            mainWindow = window
        }
        if !(window.contentView is NSHostingView<MainView>) {
            let content = NSHostingView(rootView: MainView(model: model))
            content.safeAreaRegions = []
            window.contentView = content
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Clipato",
            .applicationVersion: AppVersion.number,
            .version: AppVersion.build
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func checkForUpdates() {
        model.section = .general
        showWindow()
        model.checkForUpdates()
    }
    @objc private func captureRegion() { model.capture(region: true) }
    @objc private func captureFixedRegion() { model.captureFixedRegion() }
    @objc private func captureDisplay() { model.capture(region: false) }
    @objc private func pinLatest() { model.pinLatest() }
    @objc private func togglePinnedMousePassthrough() {
        model.screenshots.togglePinnedMousePassthrough()
        updateShortcutMenuItems()
    }
    @objc private func toggleRecording() { model.toggleRecording() }
    @objc private func toggleRecordingPause() { model.toggleRecordingPause() }
    @objc private func toggleShortcuts() { model.shortcuts.setEnabled(!model.shortcuts.isEnabled) }
    @objc private func clearOperationHistory() {
        model.clearOperationHistory()
        updateRecentImageMenuItem()
    }
    @objc private func showShortcutSettings() {
        let window: NSWindow
        if let shortcutSettingsWindow { window = shortcutSettingsWindow }
        else {
            window = EscapeClosingWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L("Clipato · 快捷键设置")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: ShortcutSettingsView(shortcuts: model.shortcuts))
            window.center()
            shortcutSettingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.clearingLibraryData else { return false }
        if sender === longScreenshotWindow, !model.collageWorkspaceSaved {
            let alert = NSAlert()
            alert.messageText = L("关闭未保存的拼图？")
            alert.informativeText = L("当前拼图尚未导出到保管箱，关闭后会丢弃本次调整。")
            alert.addButton(withTitle: L("继续编辑"))
            alert.addButton(withTitle: L("放弃并关闭"))
            return alert.runModal() == .alertSecondButtonReturn
        }
        if sender === mainWindow {
            guard model.imageProcessingRoute == nil || !model.imageProcessingNavigationBlocked else { return false }
            sender.orderOut(nil)
            model.dismissImageExport()
            model.dismissImageProcessing()
            sender.contentView = nil
            if let library = model.library {
                Task { await library.clearThumbnails() }
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === longScreenshotWindow {
            window.contentView = nil
            longScreenshotWindow = nil
            model.closeCollageWorkspace()
            updateShortcutMenuItems()
        }
        if let window = notification.object as? NSWindow, window === editorWindow {
            window.contentView = nil
            editorWindow = nil
            model.editing = nil
        }
        if let window = notification.object as? NSWindow, window === shortcutSettingsWindow {
            window.contentView = nil
            shortcutSettingsWindow = nil
            model.shortcuts.endRecording()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isPresentingError, let library = model.library else { return }
        do {
            try library.reloadImages()
            try library.reloadSessions()
            let selected = model.selected.intersection(library.images.map(\.id))
            if selected != model.selected { model.selected = selected }
        } catch { model.errorMessage = L("保管箱刷新失败：\(error.localizedDescription)") }
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.shortcuts.endRecording()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.clearingLibraryData { return .terminateCancel }
        if model.capturing || (model.recordingBusy && !model.selectingRecordingRegion) { return .terminateCancel }
        if model.fixedCaptureRegion != nil {
            model.cancelFixedCapture()
            if model.fixedCaptureRegion != nil { return .terminateCancel }
        }
        if let window = longScreenshotWindow {
            guard windowShouldClose(window) else { return .terminateCancel }
            window.close()
        }
        guard model.selectingRecordingRegion || model.recorder.isRecording || model.isExporting
                || model.library?.hasPendingStorageWork == true else { return .terminateNow }
        if model.recorder.isRecording { model.recordingBusy = true }
        Task {
            await model.cancelRecordingSelection()
            await model.cancelExportAndWait()
            do {
                if model.recorder.isRecording { try await model.stopRecording() }
                await model.library?.cancelStorageWorkAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                model.recordingBusy = false
                model.errorMessage = L("退出前保存录屏失败：\(error.localizedDescription)")
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.screenshots.cancelSelection()
        model.recordingOverlay.hide()
        model.fixedCaptureOverlay.hide()
    }
}
