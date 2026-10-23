import AppKit
import Combine
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: String, CaseIterable {
    case images = "截图保管箱"
    case recordings = "录屏"
    case imageProcessing = "图像处理"
    case collections = "收藏夹"
    case appearance = "语言与外观"
    case general = "通用设置"
    case security = "安全设置"
    case aiTerminal = "AI 终端"
    case shortcuts = "快捷键设置"
    case guide = "使用指南"

    var title: String {
        switch self {
        case .images: return L("截图保管箱")
        case .recordings: return L("录屏")
        case .imageProcessing: return L("图像处理")
        case .collections: return L("收藏夹")
        case .appearance: return L("语言与外观")
        case .general: return L("系统设置")
        case .security: return L("安全设置")
        case .aiTerminal: return L("AI 终端")
        case .shortcuts: return L("快捷键设置")
        case .guide: return L("使用指南")
        }
    }

    var icon: String {
        switch self {
        case .images: return "square.stack.3d.up"
        case .recordings: return "rectangle.on.rectangle"
        case .imageProcessing: return "slider.horizontal.3"
        case .collections: return "folder"
        case .appearance: return "paintpalette"
        case .general: return "gearshape"
        case .security: return "lock.shield"
        case .aiTerminal: return "terminal"
        case .shortcuts: return "keyboard"
        case .guide: return "questionmark.circle"
        }
    }
}

enum ImageProcessingRoute: Equatable {
    case sourceSelection(ImageProcessingCapability)
    case toolSelection(ImageTool), processing(ImageTool)
    case renameSelection, renamePreview
    case scanSelection, scanResults
}

enum ImageProcessingCapability: Equatable {
    case tool(ImageTool), rename, scan(AssetScanMode)

    var title: String {
        switch self {
        case .tool(let tool): return tool.title
        case .rename: return L("批量命名")
        case .scan(let mode): return mode.title
        }
    }
}

enum ImageProcessingSource: Equatable {
    case files, vault

    var title: String { self == .files ? L("外部图片") : L("截图保管箱") }
}

enum UpdateCheckState: Equatable {
    case idle, checking, upToDate
    case available(UpdateRelease)
    case failed(String)
}

struct EditingImage: Identifiable {
    let id = UUID()
    let image: CGImage
    var tag: AssetTag? = nil
    var collectionID: UUID? = nil
}

struct CollageSelection: Identifiable {
    let id = UUID()
    let images: [CGImage]
    var tag: AssetTag? = nil
    var collectionID: UUID? = nil
}

struct LongScreenshotSelection: Identifiable {
    let id = UUID()
    let images: [CGImage]
    let tag: AssetTag?
    var temporaryDirectory: URL? = nil
    var collectionID: UUID? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var library: LibraryStore?
    @Published var section: LibrarySection = .images
    @Published var selectedCollectionID: UUID?
    @Published private(set) var preparingCollectionFrames = false
    @Published var theme: AppTheme = .saved {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            NSApp.appearance = theme.appearance
        }
    }
    @Published var privacyMode: Bool {
        didSet {
            defaults.set(privacyMode, forKey: "privacyMode")
            if privacyMode && !oldValue { MCPSettings.setEnabled(false, in: defaults) }
            defaults.synchronize()
        }
    }
    @Published private(set) var updateCheckState = UpdateCheckState.idle
    @Published private(set) var updateCheckCachedAt: Date?
    private var updateCheckTask: Task<Void, Never>?
    @Published var selected: Set<UUID> = [] { didSet { updateStorageProtection() } }
    @Published var query = ""
    @Published var editing: EditingImage? {
        didSet {
            if editing == nil { editingSourceID = nil }
            updateStorageProtection()
        }
    }
    @Published var collage: CollageSelection? {
        didSet {
            if collage == nil { collageSourceIDs = [] }
            updateStorageProtection()
        }
    }
    @Published var longScreenshot: LongScreenshotSelection? {
        didSet {
            if longScreenshot == nil { longScreenshotSourceIDs = [] }
            updateStorageProtection()
        }
    }
    private var editingSourceID: UUID?
    private var collageSourceIDs: Set<UUID> = []
    private var longScreenshotSourceIDs: Set<UUID> = []
    private var exportSourceIDs: Set<UUID> = []
    @Published private(set) var fixedCaptureRegion: RecordingRegion?
    private var fixedCaptureFiles: [URL] = []
    private var fixedCaptureDirectory: URL?
    private var fixedCaptureTag: AssetTag?
    private var fixedCapturePending = 0
    private var fixedCaptureFinishing = false
    private var fixedCaptureTask: Task<Void, Never>?
    private let fixedCaptureImage: (RecordingRegion, [CGWindowID]) async throws -> CGImage
    var hasFixedCaptures: Bool { !fixedCaptureFiles.isEmpty }
    var canCaptureFixedRegion: Bool {
        !clearingLibraryData && !recordingBusy && !recorder.isRecording && !hasCollageWorkspace && !preparingCollectionFrames && (privacyMode || library != nil)
            && !fixedCaptureFinishing
            && (!capturing || (fixedCaptureTask != nil && fixedCaptureRegion != nil))
            && fixedCaptureFiles.count + fixedCapturePending < 256
    }
    var hasCollageWorkspace: Bool { collage != nil || longScreenshot != nil }
    var collageSaved = false
    var longScreenshotSaved = false
    var collageWorkspaceSaved: Bool { collage != nil ? collageSaved : longScreenshotSaved }
    var fixedCaptureShortcutDescription: String {
        shortcuts.isEnabled ? (shortcuts.bindings[.fixedCapture]?.displayName ?? L("鼠标点击截取")) : L("快捷键已禁用")
    }
    @Published var errorMessage: String?
    @Published private(set) var screenCapturePermissionError: String?
    @Published var notice: String? {
        didSet {
            noticeDismissal?.invalidate()
            noticeDismissal = nil
            guard notice != nil else { return }
            let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.notice = nil }
            }
            noticeDismissal = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    @Published var capturing = false
    @Published var sampleRate = 2.0
    @Published var recordingMode: RecordingMode = .keyframes
    @Published var videoFrameRate = 30.0
    @Published var threshold = 0.025
    @Published var maxDimension = 1920
    @Published var recordingBusy = false
    @Published var selectingRecordingRegion = false
    @Published var recordingRegion: RecordingRegion?
    @Published var renameItem: VaultImage?
    @Published var renameText = ""
    @Published var batchRenameAssets: [CollectionAsset] = [] { didSet { updateStorageProtection() } }
    @Published private(set) var batchRenameChanges: [CollectionAsset: CollectionAsset] = [:]
    @Published var scanAssets: [CollectionAsset] = [] { didSet { updateStorageProtection() } }
    @Published private(set) var externalRenameURLs: [URL] = []
    @Published private(set) var externalScanURLs: [URL] = []
    private(set) var scanMode = AssetScanMode.duplicates
    @Published private(set) var imageProcessingRoute: ImageProcessingRoute?
    @Published private(set) var imageProcessingSource: ImageProcessingSource?
    @Published var scanDeletionInProgress = false
    @Published private(set) var clearingLibraryData = false
    @Published private(set) var exportingSessionID: UUID?
    @Published private(set) var exportProgress = 0.0
    @Published private(set) var exportFilename = ""
    @Published private(set) var exportIsIndeterminate = false
    @Published var batchExportMode: BatchExportMode?
    private(set) var batchImageTool: ImageTool?
    @Published private var imageExportID: UUID?
    @Published private(set) var batchExportImages: [URL] = []
    var exportingImages: Bool { imageExportID != nil }
    var isExporting: Bool { exportingSessionID != nil || exportingImages }
    var imageProcessingNavigationBlocked: Bool { isExporting || scanDeletionInProgress || clearingLibraryData }
    var canClearLibraryData: Bool {
        library != nil && !clearingLibraryData && !capturing && !recordingBusy && !recorder.isRecording
            && !selectingRecordingRegion && fixedCaptureRegion == nil && !hasCollageWorkspace && editing == nil
            && !preparingCollectionFrames && !isExporting && !scanDeletionInProgress
            && imageProcessingRoute == nil && batchExportMode == nil && renameItem == nil
    }
    let recorder = KeyframeRecorder()
    let screenshots: ScreenshotController
    let recordingOverlay = RecordingRegionOverlay()
    let fixedCaptureOverlay = FixedCaptureOverlay()
    let shortcuts: ShortcutManager
    let libraryRoot: URL
    private let defaults: UserDefaults
    private var recordingTag: AssetTag?
    private var recordingTask: Task<Void, Never>?
    private var recordingMetrics: AnyCancellable?
    private var collectionChanges: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var noticeDismissal: Timer?

    init(root: URL? = nil, shortcuts: ShortcutManager? = nil, defaults: UserDefaults = .standard,
         fixedCaptureImage: ((RecordingRegion, [CGWindowID]) async throws -> CGImage)? = nil) {
        self.defaults = defaults
        let privacyMode = defaults.bool(forKey: "privacyMode")
        self.privacyMode = privacyMode
        if privacyMode {
            MCPSettings.setEnabled(false, in: defaults)
            defaults.synchronize()
        }
        self.shortcuts = shortcuts ?? ShortcutManager()
        let screenshots = ScreenshotController()
        self.screenshots = screenshots
        if let fixedCaptureImage { self.fixedCaptureImage = fixedCaptureImage }
        else {
            self.fixedCaptureImage = { region, windowIDs in
                try await screenshots.captureFixedRegion(region, excludingWindowIDs: windowIDs)
            }
        }
        libraryRoot = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameVault")
        do { library = try LibraryStore(root: libraryRoot, defaults: defaults) }
        catch { errorMessage = L("保管箱读取失败：\(error.localizedDescription)\n目录：\(libraryRoot.path)") }
        collectionChanges = library?.$collections.sink { [weak self] collections in
            guard let self else { return }
            let ids = Set(collections.map(\.id))
            var detached = false
            if let id = self.longScreenshot?.collectionID, !ids.contains(id) {
                self.longScreenshot?.collectionID = nil
                detached = true
            }
            if let id = self.collage?.collectionID, !ids.contains(id) {
                self.collage?.collectionID = nil
                detached = true
            }
            if let id = self.editing?.collectionID, !ids.contains(id) {
                self.editing?.collectionID = nil
                detached = true
            }
            if let id = self.selectedCollectionID, !ids.contains(id) {
                self.selectedCollectionID = nil
                self.selected = []
            }
            if detached { self.notice = L("来源收藏夹已删除，编辑结果仍可保存到保管箱。") }
        }
        fixedCaptureOverlay.onCapture = { [weak self] in self?.captureFixedRegion() }
        fixedCaptureOverlay.onFinish = { [weak self] in self?.finishFixedCapture() }
        fixedCaptureOverlay.onCancel = { [weak self] in self?.cancelFixedCapture() }
        fixedCaptureOverlay.onTagChange = { [weak self] in self?.fixedCaptureTag = $0 }
        fixedCaptureOverlay.onRegionChange = { [weak self] in self?.moveFixedCapture(to: $0) }
        recordingOverlay.onStop = { [weak self] in self?.toggleRecording() }
        recordingOverlay.onTagChange = { [weak self] in self?.recordingTag = $0 }
        recordingOverlay.onPause = { [weak self] in self?.toggleRecordingPause() }
        recordingMetrics = recorder.$elapsed.combineLatest(recorder.$frameCount, recorder.$isPaused).sink { [weak self] elapsed, count, paused in
            self?.recordingOverlay.update(elapsed: elapsed, frameCount: count, isPaused: paused)
        }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.recordingOverlay.hide()
            self.recordingRegion = nil
            self.reportRecordingError(error)
            self.recordingBusy = false
        }
    }

    deinit {
        noticeDismissal?.invalidate()
        updateCheckTask?.cancel()
    }

    func checkForUpdates() {
        guard updateCheckState != .checking else { return }
        updateCheckCachedAt = nil
        let urls: [URL]
        do {
            urls = try AppUpdateChecker.configuredURLs()
            guard !urls.isEmpty else { throw AppUpdateError.noManifestURLs }
        } catch {
            updateCheckState = .failed(error.localizedDescription)
            return
        }
        updateCheckState = .checking
        updateCheckTask = Task { [weak self] in
            do {
                let result = try await AppUpdateChecker.shared.check(at: urls)
                guard !Task.isCancelled else { return }
                self?.updateCheckCachedAt = result.cachedAt
                self?.updateCheckState = result.release.map(UpdateCheckState.available) ?? .upToDate
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.updateCheckState = .failed(error.localizedDescription)
            }
            self?.updateCheckTask = nil
        }
    }

    func capture(region: Bool) {
        guard !clearingLibraryData, !capturing, !recordingBusy, fixedCaptureRegion == nil, privacyMode || library != nil else { return }
        capturing = true
        Task {
            defer { capturing = false }
            do {
                if !privacyMode, let library { try library.validateStorageDirectory(for: .screenshots) }
                guard let result = try await screenshots.captureRegion(initialFullScreen: !region) else { return }
                screenCapturePermissionError = nil
                let image = result.image
                let item = try storeScreenshot(image, tag: result.tag)
                switch result.action {
                case .copy:
                    copyImage(image)
                    notice = item == nil ? L("截图已复制到剪贴板") : L("截图已保存，并复制到剪贴板")
                case .save:
                    if item != nil { notice = L("截图已保存到保管箱") }
                    let filename = try item?.filename ?? CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults)
                    export(image, filename: filename)
                case .pin:
                    screenshots.pin(image: image, frame: result.frame)
                    notice = item == nil ? L("截图已贴到屏幕") : L("截图已保存，并贴到屏幕")
                }
            } catch { reportCaptureError(error, message: error.localizedDescription) }
        }
    }

    func reportCaptureError(_ error: Error, message: String) {
        guard ScreenCapturePermission.isAuthorizationError(error) else {
            errorMessage = message
            return
        }
        screenCapturePermissionError = message
        section = .security
        NotificationCenter.default.post(name: .clipatoShowScreenCapturePermissions, object: self)
    }

    func storeScreenshot(_ image: CGImage, tag: AssetTag?) throws -> VaultImage? {
        guard !privacyMode else { return nil }
        guard let library else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("保管箱不可用，无法保存截图。")])
        }
        let filename = try CaptureFileNaming.nextFilename(for: .screenshot, extension: "png", defaults: defaults)
        return try library.addImage(image, source: "截图", filename: filename, tag: tag)
    }

    func captureFixedRegion() {
        guard !clearingLibraryData, !recordingBusy, !recorder.isRecording, !hasCollageWorkspace, !preparingCollectionFrames,
              privacyMode || library != nil else { return }
        guard !fixedCaptureFinishing else {
            notice = L("正在完成已接收的截图，请稍候。")
            return
        }
        // A running fixed capture accepts another request; selection and confirmation dialogs do not.
        guard !capturing || (fixedCaptureTask != nil && fixedCaptureRegion != nil) else { return }
        guard fixedCaptureFiles.count + fixedCapturePending < 256 else {
            errorMessage = L("已接收 256 张截图，请完成这次长图后再继续。")
            return
        }
        fixedCapturePending += 1
        updateFixedCaptureControls()
        guard fixedCaptureTask == nil else { return }
        capturing = true
        updateFixedCaptureControls()
        fixedCaptureTask = Task {
            defer {
                capturing = false
                fixedCaptureTask = nil
                updateFixedCaptureControls()
            }
            do {
                if fixedCaptureRegion == nil {
                    if !privacyMode, let library { try library.validateStorageDirectory(for: .screenshots) }
                    guard let selection = try await screenshots.selectFixedRegion(tag: fixedCaptureTag) else {
                        fixedCapturePending = 0
                        return
                    }
                    try fixedCaptureOverlay.show(selection.region, tag: selection.tag,
                                                 shortcutDescription: fixedCaptureShortcutDescription)
                    try beginFixedCapture(region: selection.region, tag: selection.tag)
                }
                let region = fixedCaptureRegion!
                let directory = fixedCaptureDirectory!
                while fixedCapturePending > 0 {
                    updateFixedCaptureControls()
                    let image = try await fixedCaptureImage(region, fixedCaptureOverlay.windowIDs)
                    screenCapturePermissionError = nil
                    let url = directory.appendingPathComponent("\(fixedCaptureFiles.count + 1).png")
                    try await Task.detached(priority: .userInitiated) { try LibraryStore.writePNG(image, to: url) }.value
                    fixedCaptureFiles.append(url)
                    fixedCapturePending -= 1
                    library?.setCacheDirectories([directory])
                }
                if fixedCaptureFinishing { try openFixedCaptureWorkbench() }
            } catch {
                let unfinished = fixedCapturePending
                fixedCapturePending = 0
                fixedCaptureFinishing = false
                if fixedCaptureRegion == nil {
                    fixedCaptureOverlay.hide()
                    removeFixedCaptureFiles()
                    reportCaptureError(error, message: error.localizedDescription)
                } else if unfinished > 0 {
                    reportCaptureError(error, message: L("连续截图未完成：\(error.localizedDescription)\n已保留 \(fixedCaptureFiles.count) 张截图，\(unfinished) 次请求未完成。可继续截取，或完成已有图片。"))
                } else {
                    errorMessage = L("长图工作台无法打开：\(error.localizedDescription)\n已保留 \(fixedCaptureFiles.count) 张截图，可重试。")
                }
            }
        }
    }

    @discardableResult
    func beginFixedCapture(region: RecordingRegion, tag: AssetTag?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-Long-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        fixedCaptureDirectory = directory
        fixedCaptureTag = tag
        fixedCaptureRegion = region
        library?.setCacheDirectories([directory])
        return directory
    }

    func moveFixedCapture(to region: RecordingRegion) {
        guard !capturing, !fixedCaptureFinishing, let current = fixedCaptureRegion,
              current.displayID == region.displayID, current.rect.size == region.rect.size else { return }
        fixedCaptureRegion = region
    }

    func finishFixedCapture() {
        guard fixedCaptureRegion != nil, !hasCollageWorkspace,
              !fixedCaptureFiles.isEmpty || fixedCapturePending > 0 else { return }
        guard !capturing || fixedCaptureTask != nil else { return }
        fixedCaptureFinishing = true
        updateFixedCaptureControls()
        guard fixedCaptureTask == nil else { return }
        capturing = true
        defer {
            capturing = false
            fixedCaptureFinishing = false
            updateFixedCaptureControls()
        }
        do {
            try openFixedCaptureWorkbench()
        } catch { errorMessage = error.localizedDescription }
    }

    private func openFixedCaptureWorkbench() throws {
        let images = try fixedCaptureFiles.map { try LibraryStore.readImage(at: $0) }
        longScreenshotSaved = false
        longScreenshot = LongScreenshotSelection(images: images, tag: fixedCaptureTag, temporaryDirectory: fixedCaptureDirectory)
        fixedCaptureOverlay.hide()
        fixedCaptureRegion = nil
        fixedCaptureFiles.removeAll()
        fixedCaptureDirectory = nil
        fixedCaptureFinishing = false
    }

    private func updateFixedCaptureControls() {
        fixedCaptureOverlay.update(count: fixedCaptureFiles.count, busy: capturing,
                                   pending: fixedCapturePending, finishing: fixedCaptureFinishing)
    }

    func cancelFixedCapture() {
        guard !capturing else { return }
        capturing = true
        fixedCaptureOverlay.update(count: fixedCaptureFiles.count, busy: true)
        defer {
            capturing = false
            fixedCaptureOverlay.update(count: fixedCaptureFiles.count, busy: false)
        }
        if hasFixedCaptures {
            let alert = NSAlert()
            alert.messageText = L("放弃这次连续截图？")
            alert.informativeText = L("已截取的 \(fixedCaptureFiles.count) 张图片尚未保存到保管箱。")
            alert.addButton(withTitle: L("继续截图"))
            alert.addButton(withTitle: L("放弃"))
            fixedCaptureOverlay.setTemporarilyHidden(true)
            guard alert.runModal() == .alertSecondButtonReturn else {
                fixedCaptureOverlay.setTemporarilyHidden(false)
                return
            }
        }
        fixedCaptureOverlay.hide()
        fixedCaptureRegion = nil
        removeFixedCaptureFiles()
    }

    private func removeFixedCaptureFiles() {
        if let directory = fixedCaptureDirectory {
            do {
                try FileManager.default.removeItem(at: directory)
                library?.setCacheDirectories([])
            }
            catch { errorMessage = L("临时截图清理失败：\(error.localizedDescription)\n\(directory.path)") }
        }
        fixedCaptureFiles.removeAll()
        fixedCaptureDirectory = nil
    }

    func selectCollection(_ id: UUID) {
        selectedCollectionID = id
        selected = []
        query = ""
        section = .collections
    }

    func composeLongScreenshot(images: [VaultImage]? = nil, collectionID: UUID? = nil) {
        if hasCollageWorkspace {
            NotificationCenter.default.post(name: .clipatoShowCollageWorkspace, object: self)
            return
        }
        guard let library, !preparingCollectionFrames,
              fixedCaptureRegion == nil, !capturing else { return }
        do {
            let items = images ?? Array(library.images.filter { selected.contains($0.id) }.reversed())
            guard !items.isEmpty else { return }
            let images = try items.map { try library.loadImage($0) }
            longScreenshotSaved = false
            longScreenshotSourceIDs = Set(items.map(\.id))
            longScreenshot = LongScreenshotSelection(images: images, tag: nil, collectionID: collectionID)
        } catch { errorMessage = error.localizedDescription }
    }

    func saveLongScreenshot(_ image: CGImage, tag: AssetTag?) throws {
        guard let library else { throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("保管箱不可用，无法保存长图。请先拷贝图片。")] ) }
        let item = try library.addImage(image, source: "长截图", tag: tag, collectionID: longScreenshot?.collectionID)
        selected = [item.id]
        longScreenshotSaved = true
        notice = L("长截图已保存到保管箱")
    }

    func closeLongScreenshot() {
        let directory = longScreenshot?.temporaryDirectory
        longScreenshot = nil
        longScreenshotSaved = false
        if let directory {
            do {
                try FileManager.default.removeItem(at: directory)
                library?.setCacheDirectories([])
            }
            catch { errorMessage = L("临时截图清理失败：\(error.localizedDescription)\n\(directory.path)") }
        }
    }

    func markCollageChanged() {
        if collage != nil { collageSaved = false }
        if longScreenshot != nil { longScreenshotSaved = false }
    }

    func closeCollageWorkspace() {
        collage = nil
        collageSaved = false
        closeLongScreenshot()
    }

    private func reportRecordingError(_ error: Error, includeSession: Bool = true) {
        var message = L("录屏未完成：\(error.localizedDescription)")
        if includeSession, let directory = recorder.sessionDirectory {
            message += L("\n已写入的录制文件保留在：\(directory.path)")
            do { try library?.setRecordingTag(recordingTag, for: directory) }
            catch { message += L("\n录制标签保存失败：\(error.localizedDescription)") }
        }
        do { try library?.reloadSessions() }
        catch { message += L("\n录制列表读取失败：\(error.localizedDescription)") }
        reportCaptureError(error, message: message)
    }

    func importImages() {
        guard !clearingLibraryData, let library else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("导入的图片保留原文件名与原始文件内容。")
        if panel.runModal() == .OK {
            do {
                try library.importImages(panel.urls)
                section = .images
                notice = L("已导入 \(panel.urls.count) 张图片")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func saveEdited(_ image: CGImage, tag: AssetTag?) throws {
        guard let library else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("保管箱不可用，无法保存标注图片。")])
        }
        let item = try library.addImage(image, source: "标注", tag: tag, collectionID: editing?.collectionID)
        selected = [item.id]
        notice = L("标注图片已保存")
    }

    func compose(images: [VaultImage]? = nil, collectionID: UUID? = nil) {
        if hasCollageWorkspace {
            NotificationCenter.default.post(name: .clipatoShowCollageWorkspace, object: self)
            return
        }
        guard let library, !preparingCollectionFrames,
              fixedCaptureRegion == nil, !capturing else { return }
        do {
            let items = images ?? Array(library.images.filter { selected.contains($0.id) }.reversed())
            guard !items.isEmpty else { return }
            let images = try items.map { try library.loadImage($0) }
            collageSaved = false
            collageSourceIDs = Set(items.map(\.id))
            collage = CollageSelection(images: images, collectionID: collectionID)
        } catch { errorMessage = error.localizedDescription }
    }

    func composeKeyframes(_ session: SavedSession, indices: [Int], collectionID: UUID, longScreenshot: Bool) async -> Bool {
        guard !preparingCollectionFrames, !indices.isEmpty, let library else { return false }
        guard !hasCollageWorkspace, fixedCaptureRegion == nil, !capturing else {
            errorMessage = L("请先完成当前拼图或连续截图，再打开选中的关键帧。")
            return false
        }
        guard library.collections.contains(where: { $0.id == collectionID }) else {
            errorMessage = CollectionError.missingCollection.localizedDescription
            return false
        }
        preparingCollectionFrames = true
        defer { preparingCollectionFrames = false }
        let task = Task.detached(priority: .userInitiated) {
            try indices.sorted().map { index in
                try Task.checkCancellation()
                let url = try session.frameURL(at: index)
                try KeyframeExporter.validatePNGEnd(at: url)
                let image = try LibraryStore.readImage(at: url)
                guard image.width == session.manifest.width, image.height == session.manifest.height else {
                    throw KeyframeExportError.invalidFrame(url)
                }
                return image
            }
        }
        do {
            let images = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard library.collections.contains(where: { $0.id == collectionID }) else { throw CollectionError.missingCollection }
            guard batchExportMode == nil, editing == nil else {
                errorMessage = L("请先完成当前导出或标注，再打开选中的关键帧。")
                return false
            }
            guard !hasCollageWorkspace, fixedCaptureRegion == nil, !capturing else {
                errorMessage = L("请先完成当前拼图或连续截图，再打开选中的关键帧。")
                return false
            }
            if longScreenshot {
                longScreenshotSaved = false
                longScreenshotSourceIDs = []
                self.longScreenshot = LongScreenshotSelection(images: images, tag: library.recordingTags[session.directory], collectionID: collectionID)
            } else {
                collageSaved = false
                collageSourceIDs = []
                collage = CollageSelection(images: images, tag: library.recordingTags[session.directory], collectionID: collectionID)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveCollage(_ image: CGImage, tag: AssetTag?, mode: CollageWorkspaceMode) throws {
        guard let library else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("保管箱不可用，无法保存拼图。请先拷贝图片。")])
        }
        let collectionID = collage?.collectionID ?? longScreenshot?.collectionID
        let item = try library.addImage(image, source: mode == .longScreenshot ? "长截图" : "拼图", tag: tag, collectionID: collectionID)
        selected = [item.id]
        if collage != nil { collageSaved = true }
        if longScreenshot != nil { longScreenshotSaved = true }
        notice = mode == .longScreenshot ? L("长截图已保存到保管箱") : L("拼图已保存到保管箱")
    }

    func edit(_ item: VaultImage) {
        guard let library else { return }
        do {
            let image = try library.loadImage(item)
            editingSourceID = item.id
            editing = EditingImage(image: image, tag: item.tag, collectionID: section == .collections ? selectedCollectionID : nil)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func pin(_ item: VaultImage) {
        guard let library else { return }
        do {
            let image = try library.loadImage(item)
            try library.rememberImage(item.id)
            screenshots.pin(image: image)
        }
        catch { errorMessage = error.localizedDescription }
    }

    func pinLatest() {
        guard !clearingLibraryData else { return }
        guard let library else {
            errorMessage = L("保管箱不可用，无法贴图。")
            return
        }
        do {
            guard let item = try library.recentImage() else { return }
            pin(item)
        } catch { errorMessage = error.localizedDescription }
    }

    func clearOperationHistory() {
        guard !clearingLibraryData else { return }
        guard let library else {
            errorMessage = L("保管箱不可用，无法清空操作历史。")
            return
        }
        do {
            try library.clearOperationHistory()
            notice = L("已清空操作历史")
        } catch { errorMessage = error.localizedDescription }
    }

    func clearLibraryData(options: LibraryCleanupOptions) {
        guard !options.isEmpty, canClearLibraryData, let library else { return }
        clearingLibraryData = true
        Task {
            defer { clearingLibraryData = false }
            do {
                try await library.clearAllMedia(options: options)
                selected.formIntersection(Set(library.images.map(\.id)))
                notice = L("数据清理完成")
            } catch {
                selected.formIntersection(Set(library.images.map(\.id)))
                errorMessage = L("清空未完成：\(error.localizedDescription)")
            }
            await library.clearThumbnails()
            await library.refreshStorageUsage(enforceQuota: false)
        }
    }

    @discardableResult
    func copyImage(_ image: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))])
    }

    func copy(_ item: VaultImage) {
        guard let library else { return }
        do {
            copyImage(try library.loadImage(item))
            notice = L("图片已复制")
        } catch { errorMessage = error.localizedDescription }
    }

    func export(_ image: CGImage, filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = privacyMode
            ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            : library?.screenshotDirectory
        panel.nameFieldStringValue = filename
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try LibraryStore.writePNG(image, to: url)
                notice = L("已导出 \(url.lastPathComponent)")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func prepareImageExport(_ images: [VaultImage], mode: BatchExportMode, tool: ImageTool? = nil) {
        guard !imageProcessingNavigationBlocked, !images.isEmpty, let library else { return }
        guard tool != .grid || images.count == 1 else {
            errorMessage = L("宫格切图仅支持单张图片。")
            return
        }
        dismissImageProcessing()
        exportSourceIDs = Set(images.map(\.id))
        updateStorageProtection()
        batchExportImages = images.map(library.imageURL)
        batchImageTool = tool
        if let tool {
            imageProcessingSource = .vault
            imageProcessingRoute = .processing(tool)
            section = .imageProcessing
        }
        batchExportMode = mode
    }

    func chooseExternalImageProcessing(_ capability: ImageProcessingCapability) {
        guard !imageProcessingNavigationBlocked else { return }
        let panel = NSOpenPanel()
        panel.title = L("选择要处理的图片")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = capability != .tool(.grid)
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do { try prepareExternalImages(panel.urls, for: capability) }
        catch { errorMessage = error.localizedDescription }
    }

    func prepareExternalImages(_ sourceURLs: [URL], for capability: ImageProcessingCapability) throws {
        guard !imageProcessingNavigationBlocked else { return }
        let urls = try validatedProcessingImages(sourceURLs)
        switch capability {
        case .tool(.grid):
            guard urls.count == 1 else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("宫格切图仅支持单张图片。")])
            }
        case .rename, .scan:
            guard urls.count >= 2 else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("请至少选择 2 张图片。")])
            }
            try validateExternalProcessingFiles(urls)
        case .tool: break
        }
        guard !urls.isEmpty else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("请至少选择一张图片。")])
        }
        dismissImageProcessing()
        imageProcessingSource = .files
        section = .imageProcessing
        switch capability {
        case .tool(let tool):
            batchExportImages = urls
            protectImageExportSources(urls)
            batchImageTool = tool
            imageProcessingRoute = .processing(tool)
            batchExportMode = .files
        case .rename:
            externalRenameURLs = urls
            imageProcessingRoute = .renamePreview
        case .scan(let mode):
            scanMode = mode
            externalScanURLs = urls
            imageProcessingRoute = .scanResults
        }
    }

    private func validateExternalProcessingFiles(_ urls: [URL]) throws {
        guard let library else { throw CollectionError.missingAsset }
        try library.reloadImages()
        try library.reloadSessions()
        let directories = [library.root, library.screenshotDirectory, library.recordingDirectory]
            + library.storage.recordingDirectories + library.images.compactMap(\.directory)
        let roots = Set(directories.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        let managed = library.images.map(library.imageURL) + library.videos
        let managedPaths = Set(managed.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        var linkedFiles: [stat] = []
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !managedPaths.contains(path), !roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("保管箱中的图片请从「截图保管箱」选择。")
                ])
            }
            let values = try scannedFileValues(at: url)
            if values.st_nlink > 1 { linkedFiles.append(values) }
        }
        guard !linkedFiles.isEmpty else { return }
        for url in managed {
            var values = stat()
            guard lstat(url.path, &values) == 0 else {
                if errno == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
            }
            guard !linkedFiles.contains(where: { $0.st_dev == values.st_dev && $0.st_ino == values.st_ino }) else {
                throw NSError(domain: "Clipato", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: L("保管箱中的图片请从「截图保管箱」选择。")
                ])
            }
        }
    }

    func appendImageExportSources(_ urls: [URL]) throws {
        guard !isExporting else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("请先完成当前导出。")])
        }
        let added = try validatedProcessingImages(urls)
        let existing = Set(batchExportImages)
        batchExportImages.append(contentsOf: added.filter { !existing.contains($0) })
        protectImageExportSources(added)
    }

    private func protectImageExportSources(_ urls: [URL]) {
        let urls = Set(urls)
        if let library {
            exportSourceIDs.formUnion(library.images.filter { urls.contains(library.imageURL($0)) }.map(\.id))
        }
        updateStorageProtection()
    }

    private func validatedProcessingImages(_ urls: [URL]) throws -> [URL] {
        var seen: Set<URL> = []
        var images: [URL] = []
        for url in urls {
            guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSURLErrorKey: url]) }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0 else { throw LibraryError.unreadableImage(url.lastPathComponent) }
            if seen.insert(url).inserted { images.append(url) }
        }
        return images
    }

    func dismissImageExport() {
        if exportingImages { exportTask?.cancel() }
        else { exportSourceIDs = []; updateStorageProtection() }
        batchExportMode = nil
        batchExportImages = []
        batchImageTool = nil
        if case .processing = imageProcessingRoute { imageProcessingRoute = nil }
    }

    func exportImages(options: BatchExportOptions) {
        guard !isExporting, !batchExportImages.isEmpty else { return }
        let images = batchExportImages
        let output: URL
        let exportsDirectory = options.mode == .files && (options.grid != nil || options.processing != nil || options.imageFormat != .pdf)
        if exportsDirectory {
            let panel = NSOpenPanel()
            panel.title = L("导出图片")
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.directoryURL = library?.screenshotDirectory
            panel.message = L("选择导出目录；已有同名文件不会被覆盖。")
            guard panel.runModal() == .OK, let directory = panel.url else { return }
            output = directory
        } else {
            let panel = NSSavePanel()
            let contentType: UTType
            let extensionName: String
            switch options.mode {
            case .files:
                contentType = .pdf
                extensionName = "pdf"
            case .zip:
                contentType = .zip
                extensionName = "zip"
            case .video:
                contentType = options.videoFormat == .mp4 ? .mpeg4Movie : .gif
                extensionName = options.videoFormat.rawValue
            }
            panel.title = L("导出\(options.mode == .zip ? L("压缩包") : options.mode == .video ? options.videoFormat.title : "PDF")")
            panel.allowedContentTypes = [contentType]
            panel.directoryURL = library?.screenshotDirectory
            panel.nameFieldStringValue = "Clipato-\(images.count)张图片.\(extensionName)"
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            output = url
        }
        let id = UUID()
        imageExportID = id
        exportFilename = output.lastPathComponent
        exportProgress = 0
        exportIsIndeterminate = false
        exportTask = Task {
            defer {
                imageExportID = nil
                exportTask = nil
                let keepsProcessingDraft: Bool
                if case .processing = imageProcessingRoute { keepsProcessingDraft = true }
                else { keepsProcessingDraft = false }
                if !keepsProcessingDraft {
                    batchExportMode = nil
                    batchExportImages = []
                    batchImageTool = nil
                    exportSourceIDs = []
                    updateStorageProtection()
                }
            }
            do {
                try await BatchImageExporter.export(images: images, output: output, options: options,
                                                    overwrite: !exportsDirectory) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.imageExportID == id else { return }
                        self.exportProgress = progress
                    }
                }
                let count: Int
                if let grid = options.grid { count = grid.divisions * grid.divisions }
                else { count = options.processing.map { $0.resizeEnabled ? images.count * $0.sizes.count : images.count } ?? images.count }
                notice = exportsDirectory ? L("已导出 \(count) 张图片") : L("已导出 \(output.lastPathComponent)")
            } catch is CancellationError {
                notice = L("已取消导出")
            } catch {
                errorMessage = L("导出失败：\(imageProcessingErrorDescription(error))")
            }
        }
    }

    func exportSession(_ session: SavedSession, format: KeyframeExportFormat) {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = L("导出\(format.title)")
        panel.directoryURL = library?.recordingDirectory
        panel.allowedContentTypes = [format == .mp4 ? .mpeg4Movie : .gif]
        let name = session.manifest.name ?? "Clipato-\(session.id.uuidString.prefix(8))"
        panel.nameFieldStringValue = "\(name).\(format.rawValue)"
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let output = panel.url else { return }

        exportingSessionID = session.id
        exportFilename = output.lastPathComponent
        exportProgress = 0
        exportIsIndeterminate = false
        let sessionID = session.id
        exportTask = Task {
            defer {
                exportingSessionID = nil
                exportTask = nil
            }
            do {
                try await KeyframeExporter.export(directory: session.directory, output: output, format: format,
                                                  maxDimension: format.defaultMaxDimension, overwrite: true) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportingSessionID == sessionID else { return }
                        self.exportProgress = progress
                    }
                }
                notice = L("已导出 \(output.lastPathComponent)")
            } catch is CancellationError {
                notice = L("已取消导出")
            } catch {
                errorMessage = L("导出失败：\(error.localizedDescription)")
            }
        }
    }

    func exportSessionToVault(_ session: SavedSession) {
        guard !isExporting, let library else { return }
        exportingSessionID = session.id
        exportFilename = L("保管箱")
        exportProgress = 0
        exportIsIndeterminate = true
        exportTask = Task {
            defer {
                exportingSessionID = nil
                exportIsIndeterminate = false
                exportTask = nil
            }
            do {
                let count = try await library.importKeyframes(session)
                notice = L("已将 \(count) 个关键帧导出到保管箱")
            } catch is CancellationError {
                notice = L("已取消导出")
            } catch {
                errorMessage = L("导出到保管箱失败：\(error.localizedDescription)")
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    private func updateStorageProtection() {
        var ids = selected.union(exportSourceIDs).union(collageSourceIDs).union(longScreenshotSourceIDs)
        for case .image(let id) in batchRenameAssets { ids.insert(id) }
        for case .image(let id) in scanAssets { ids.insert(id) }
        if let editingSourceID { ids.insert(editingSourceID) }
        library?.setProtectedImageIDs(ids)
    }

    func cancelExportAndWait() async {
        guard let exportTask else { return }
        exportTask.cancel()
        await exportTask.value
    }

    var selectedImageCollectionCount: Int {
        guard let library else { return 0 }
        let assets = Set(selected.map(CollectionAsset.image))
        return library.collectionMembers.values.reduce(into: 0) { count, members in
            if !members.isDisjoint(with: assets) { count += 1 }
        }
    }

    func deleteSelected() {
        guard let library else { return }
        do {
            try library.delete(library.images.filter { selected.contains($0.id) })
            selected = []
            notice = L("图片已移入系统废纸篓")
        } catch { errorMessage = error.localizedDescription }
    }

    func rename() {
        guard let library, let item = renameItem else { return }
        do { try library.rename(item, to: renameText) }
        catch { errorMessage = error.localizedDescription }
        renameItem = nil
    }

    func prepareBatchRename(_ assets: [CollectionAsset]) {
        guard BatchRenameRule.supports(assets) else { return }
        guard !imageProcessingNavigationBlocked, !recordingBusy else {
            errorMessage = L("请先完成当前操作，再批量命名。")
            return
        }
        dismissImageProcessing()
        batchRenameAssets = assets
        imageProcessingSource = .vault
        imageProcessingRoute = .renamePreview
        section = .imageProcessing
    }

    func batchRename(rule: BatchRenameRule) throws {
        if !externalRenameURLs.isEmpty {
            try validateExternalProcessingFiles(externalRenameURLs)
            let count = externalRenameURLs.count
            defer { if let library { Task { await library.clearThumbnails() } } }
            _ = try BatchRenameStep.execute(urls: externalRenameURLs, rule: rule)
            dismissImageProcessing()
            notice = L("命名完成：\(count) 个文件")
            return
        }
        guard let library else {
            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("保管箱不可用。")])
        }
        let assets = batchRenameAssets
        let renamed = try BatchRenameStep(assets: assets, rule: rule).execute(in: library)
        batchRenameChanges = Dictionary(uniqueKeysWithValues: zip(assets, renamed))
        batchRenameAssets = []
        if imageProcessingRoute == .renamePreview {
            imageProcessingRoute = nil
            imageProcessingSource = nil
        }
        notice = L("命名完成：\(assets.count) 个文件")
    }

    func batchRenameSourceURLs() throws -> [URL] {
        if !externalRenameURLs.isEmpty { return externalRenameURLs }
        guard let library else { throw CollectionError.missingAsset }
        return try library.batchRenameURLs(for: batchRenameAssets)
    }

    func selectImageProcessing(_ tool: ImageTool) {
        selectImageProcessingSource(.tool(tool))
    }

    func selectBatchRename() {
        selectImageProcessingSource(.rename)
    }

    func selectImageProcessingSource(_ capability: ImageProcessingCapability) {
        guard !imageProcessingNavigationBlocked, capability != .rename || !recordingBusy else { return }
        dismissImageProcessing()
        if case .scan(let mode) = capability { scanMode = mode }
        imageProcessingRoute = .sourceSelection(capability)
        section = .imageProcessing
    }

    func chooseVaultImageProcessing(_ capability: ImageProcessingCapability) {
        guard !imageProcessingNavigationBlocked else { return }
        dismissImageProcessing()
        imageProcessingSource = .vault
        section = .imageProcessing
        switch capability {
        case .tool(let tool):
            if tool == .grid, selected.count > 1 { selected = [] }
            imageProcessingRoute = .toolSelection(tool)
        case .rename: imageProcessingRoute = .renameSelection
        case .scan(let mode):
            scanMode = mode
            imageProcessingRoute = .scanSelection
        }
    }

    func returnToImageProcessingInput() {
        guard !imageProcessingNavigationBlocked else { return }
        switch imageProcessingRoute {
        case .processing(let tool):
            guard imageProcessingSource == .vault else {
                selectImageProcessingSource(.tool(tool))
                return
            }
            let urls = Set(batchExportImages)
            if let library {
                selected = Set(library.images.filter { urls.contains(library.imageURL($0)) }.map(\.id))
            }
            chooseVaultImageProcessing(.tool(tool))
        case .renamePreview:
            guard imageProcessingSource == .vault else {
                selectImageProcessingSource(.rename)
                return
            }
            guard batchRenameAssets.allSatisfy({ if case .image = $0 { return true }; return false }) else { return }
            selected = Set(batchRenameAssets.compactMap { if case .image(let id) = $0 { return id }; return nil })
            chooseVaultImageProcessing(.rename)
        case .scanResults:
            if imageProcessingSource == .vault {
                selected = Set(scanAssets.compactMap { if case .image(let id) = $0 { return id }; return nil })
                chooseVaultImageProcessing(.scan(scanMode))
            } else { selectImageProcessingSource(.scan(scanMode)) }
        default: break
        }
    }

    func dismissImageProcessing() {
        guard !imageProcessingNavigationBlocked else { return }
        dismissImageExport()
        batchRenameAssets = []
        scanAssets = []
        externalRenameURLs = []
        externalScanURLs = []
        imageProcessingSource = nil
        imageProcessingRoute = nil
    }

    func selectAssetScan(_ mode: AssetScanMode) {
        guard !imageProcessingNavigationBlocked else { return }
        if imageProcessingRoute == .scanResults {
            selected = Set(scanAssets.compactMap { if case .image(let id) = $0 { return id }; return nil })
        }
        selectImageProcessingSource(.scan(mode))
    }

    func dismissAssetScan() {
        guard !imageProcessingNavigationBlocked else { return }
        dismissImageProcessing()
    }

    func prepareAssetScan(_ assets: [CollectionAsset], mode: AssetScanMode) {
        let eligible = mode.eligibleAssets(in: assets)
        guard eligible.count >= 2, !imageProcessingNavigationBlocked else { return }
        dismissImageProcessing()
        scanMode = mode
        scanAssets = eligible
        imageProcessingSource = .vault
        imageProcessingRoute = .scanResults
        section = .imageProcessing
    }

    func trashScannedAssets(_ items: [(asset: CollectionAsset, url: URL)]) throws {
        guard let library else { throw CollectionError.missingAsset }
        let permitted = Set(scanAssets)
        let ids = Set(items.compactMap { if case .image(let id) = $0.asset { return id }; return nil })
        let images = library.images.filter { ids.contains($0.id) }
        let imagesByID = Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
        let videos = Set(library.videos)
        for (asset, url) in items {
            guard permitted.contains(asset) else { throw CollectionError.missingAsset }
            switch asset {
            case .image(let id):
                guard let image = imagesByID[id], library.imageURL(image) == url else { throw CollectionError.missingAsset }
            case .video(let current):
                guard current == url, videos.contains(current) else { throw CollectionError.missingAsset }
            case .session: throw CollectionError.missingAsset
            }
        }
        if !images.isEmpty { try library.delete(images) }
        for (asset, url) in items {
            if case .video = asset { try library.deleteVideo(url) }
        }
    }

    func trashScannedFiles(_ urls: [URL]) throws {
        let permitted = Set(externalScanURLs)
        guard imageProcessingRoute == .scanResults, imageProcessingSource == .files,
              !urls.isEmpty, urls.allSatisfy(permitted.contains) else { throw CollectionError.missingAsset }
        try validateExternalProcessingFiles(urls)
        defer { if let library { Task { await library.clearThumbnails() } } }
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            externalScanURLs.removeAll { $0 == url }
        }
    }

    func toggleRecording() {
        guard !clearingLibraryData, !recordingBusy, fixedCaptureRegion == nil, let library, recorder.isRecording || !capturing else { return }
        recordingBusy = true
        section = .recordings
        selectingRecordingRegion = !recorder.isRecording
        if selectingRecordingRegion {
            NSApp.windows.filter { $0.isVisible && $0.title == "Clipato" }.forEach { $0.orderOut(nil) }
        }
        recordingTask = Task {
            var directory = recorder.isRecording ? recorder.sessionDirectory : nil
            defer {
                selectingRecordingRegion = false
                recordingBusy = false
                recordingTask = nil
            }
            do {
                if recorder.isRecording {
                    try await stopRecording()
                    notice = L("\(recorder.mode.title)已保存")
                } else {
                    try library.validateStorageDirectory(for: .recordings)
                    guard let selection = try await screenshots.selectRecordingRegion(mode: recordingMode) else {
                        notice = L("已取消录屏选区")
                        return
                    }
                    try Task.checkCancellation()
                    let region = selection.region
                    recordingMode = selection.mode
                    recordingTag = selection.tag
                    selectingRecordingRegion = false
                    let displays = try await recorder.availableDisplays()
                    try Task.checkCancellation()
                    guard let display = displays.first(where: { $0.displayID == region.displayID }) else {
                        throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("所选屏幕已断开，请重新框选录屏区域。")])
                    }
                    let output = try library.newRecordingDirectory()
                    let filename = try CaptureFileNaming.nextFilename(for: .recording, extension: "mp4", defaults: defaults)
                    let name = (filename as NSString).deletingPathExtension
                    directory = output
                    try await recorder.start(display: display, region: region, directory: output,
                                             sampleRate: selection.mode == .video ? videoFrameRate : sampleRate,
                                             threshold: threshold, maxDimension: maxDimension, mode: selection.mode, name: name)
                    screenCapturePermissionError = nil
                    do { try recordingOverlay.show(region, mode: recorder.mode, tag: recordingTag) }
                    catch {
                        let overlayError = error
                        do { try await stopRecording() }
                        catch {
                            throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey: L("录屏区域标记失败：\(overlayError.localizedDescription)\n停止录屏失败：\(error.localizedDescription)")])
                        }
                        throw overlayError
                    }
                    recordingRegion = region
                    notice = L("正在录制绿框内区域 · 浮动条可暂停、继续或停止")
                }
            } catch is CancellationError {
                notice = L("已取消录屏选区")
            } catch {
                recordingOverlay.hide()
                recordingRegion = nil
                reportRecordingError(error, includeSession: directory != nil && directory == recorder.sessionDirectory)
            }
        }
    }

    func toggleRecordingPause() {
        guard recorder.isRecording, !recordingBusy else { return }
        recordingBusy = true
        recordingOverlay.setPauseTransition(true)
        Task {
            defer {
                recordingBusy = false
                recordingOverlay.setPauseTransition(false)
            }
            do {
                try await recorder.setPaused(!recorder.isPaused)
                if recorder.isRecording {
                    notice = recorder.isPaused ? L("录屏已暂停，可继续录制或停止保存") : L("已继续录屏")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopRecording() async throws {
        recordingOverlay.setStopping()
        defer {
            recordingOverlay.hide()
            recordingRegion = nil
        }
        let directory = recorder.sessionDirectory
        var stopError: Error?
        do { _ = try await recorder.stop() }
        catch { stopError = error }
        do {
            if let directory { try library?.setRecordingTag(recordingTag, for: directory) }
        } catch {
            if let stopError {
                throw NSError(domain: "Clipato", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    L("\(stopError.localizedDescription)\n录制标签保存失败：\(error.localizedDescription)")])
            }
            throw error
        }
        if let stopError { throw stopError }
        try library?.reloadSessions()
    }

    func cancelRecordingSelection() async {
        guard selectingRecordingRegion, let recordingTask else { return }
        recordingTask.cancel()
        screenshots.cancelSelection()
        await recordingTask.value
    }

    func openScreenPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
