import SwiftUI
import AppKit

struct RecordingView: View {
    @Environment(\.consoleFontScale) private var fontScale
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    let recorder: KeyframeRecorder
    @State private var isRecording = false
    @State private var deleting: SavedSession?
    @State private var deletingVideo: URL?
    @AppStorage("recordingCollectionFilter") private var collectionFilter = CollectionFilter.all
    @AppStorage("recordingDisplayMode") private var displayMode = VaultDisplayMode.imagesOnly
    @State private var query = ""
    @State private var tagFilter = AssetTagFilter.all
    @State private var sortOrder = AssetSortOrder.newest
    @State private var fileInfo: [URL: AssetFileInfo] = [:]
    @State private var creationDates: [URL: Date] = [:]
    @State private var fileInfoLoader = AssetFileInfoLoader()
    @State private var refreshingFileInfo = false
    @State private var selected: Set<CollectionAsset> = []
    @State private var anchor: CollectionAsset?
    @State private var recordingThumbnailVersion = 0

    private var recordingURLs: [URL] { library.videos + library.sessions.map(\.directory) }
    private var sessionsByURL: [URL: SavedSession] { Dictionary(uniqueKeysWithValues: library.sessions.map { ($0.directory, $0) }) }
    private var columns: [GridItem] {
        let scale = max(1, fontScale)
        if displayMode == .imagesOnly {
            return [GridItem(.adaptive(minimum: 150 * scale, maximum: 220 * scale), spacing: 3)]
        }
        return [GridItem(.adaptive(minimum: 215 * scale, maximum: 330 * scale), spacing: 16)]
    }

    private var filteredURLs: [URL] {
        let sessions = sessionsByURL
        let collectedAssets = collectionFilter == .unfiled
            ? library.collectionMembers.values.reduce(into: Set<CollectionAsset>()) { $0.formUnion($1) }
            : []
        return recordingURLs.filter { url in
            let asset: CollectionAsset = sessions[url].map { .session($0.id) } ?? .video(url)
            return collectionFilter.includes(asset, collectedAssets: collectedAssets)
                && tagFilter.includes(library.recordingTags[sessions[url] == nil ? url.deletingLastPathComponent() : url])
                && (query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query)
                    || sessions[url]?.manifest.name?.localizedCaseInsensitiveContains(query) == true
                    || sessions[url]?.manifest.createdAt.formatted(
                        Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale)
                    ).localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var visibleURLs: [URL] {
        let sessions = sessionsByURL
        return sortOrder.sorted(filteredURLs, date: { url in
            if let session = sessions[url] { return session.manifest.createdAt }
            return creationDates[url]
        }, size: { fileInfo[$0]?.byteCount }, name: { sessions[$0]?.manifest.name ?? $0.lastPathComponent })
    }

    private var visibleAssets: Set<CollectionAsset> {
        let sessions = sessionsByURL
        return Set(filteredURLs.map { url in
            if let session = sessions[url] { return .session(session.id) }
            return .video(url)
        })
    }

    private var selectedAssets: Set<CollectionAsset> { selected.intersection(visibleAssets) }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                filterControls
                ScrollView(.horizontal) { filterControls.fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden)
            }
            .frame(height: 28 * max(1, fontScale)).padding(.horizontal, 24).padding(.vertical, 10)
            Label(L("录屏不支持录音，主要用于后续按帧截取图片。"), systemImage: "mic.slash")
                .consoleFont(11).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isRecording || model.selectingRecordingRegion || model.recordingBusy || !library.recordingReadErrors.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            if isRecording {
                                RecordingStatusView(recorder: recorder, region: model.recordingRegion)
                            } else if model.selectingRecordingRegion {
                                Label(L("正在框选录屏区域 · 拖动选择，Esc 取消"), systemImage: "viewfinder")
                                    .consoleFont(12).foregroundStyle(Palette.accent)
                            } else if model.recordingBusy {
                                Label(L("正在准备或保存录屏…"), systemImage: "hourglass")
                                    .consoleFont(12).foregroundStyle(Palette.muted)
                            }
                            ForEach(library.recordingReadErrors, id: \.self) { error in
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .consoleFont(11).foregroundStyle(.orange)
                            }
                        }.padding(.horizontal, 24)
                    }
                    if library.sessions.isEmpty && library.videos.isEmpty {
                        VStack(spacing: 8) {
                            Text(L("还没有录制档案")).consoleFont(13, weight: .medium)
                            Text(L("点击右上角开始录屏，录制选项可在系统设置中调整。"))
                                .consoleFont(12).foregroundStyle(Palette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 36)
                    } else {
                        recordings
                    }
                }.padding(.bottom, displayMode == .imagesOnly ? 12 : 20)
            }
            selectionBar
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipatoSelectAllVisibleAssets, object: model)) { _ in
            guard model.section == .recordings else { return }
            anchor = nil
            selected = visibleAssets
        }
        .onReceive(recorder.$isRecording.removeDuplicates()) { isRecording = $0 }
        .onReceive(model.$batchRenameChanges) { changes in
            guard !changes.isEmpty else { return }
            let renames = Dictionary(uniqueKeysWithValues: changes.compactMap { source, destination -> (URL, URL)? in
                guard case .video(let sourceURL) = source, case .video(let destinationURL) = destination else { return nil }
                return sourceURL == destinationURL ? nil : (sourceURL, destinationURL)
            })
            // Exchanging names keeps the URLs unchanged but swaps their video frames.
            if !renames.isEmpty { recordingThumbnailVersion += 1 }
            let previousInfo = fileInfo
            let previousDates = creationDates
            fileInfo = remappingAssetMetadata(previousInfo, renames: renames)
            creationDates = remappingAssetMetadata(previousDates, renames: renames)
            selected = Set(selected.map { changes[$0] ?? $0 })
            if let anchor { self.anchor = changes[anchor] ?? anchor }
        }
        .onChange(of: visibleAssets) { _, current in selected.formIntersection(current) }
        .onChange(of: visibleURLs) { _, _ in anchor = nil }
        .task(id: recordingURLs) {
            let urls = recordingURLs
            do {
                let result = try await fileInfoLoader.load(urls, includingCreationDates: true)
                let dates = await fileInfoLoader.creationDates
                try Task.checkCancellation()
                if urls == recordingURLs { fileInfo = result; creationDates = dates }
            } catch is CancellationError {
            } catch { model.errorMessage = error.localizedDescription }
        }
        .onChange(of: model.exportingSessionID) { previous, current in
            guard current == nil, let previous,
                  let session = library.sessions.first(where: { $0.id == previous }) else { return }
            Task { await refreshFileInfo(for: [session.directory]) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.exportingSessionID != nil {
                exportStatus.padding(.horizontal, 24).padding(.top, 16)
            }
        }
        .confirmationDialog(L("将这段视频移入系统废纸篓？"), isPresented: Binding(get: { deletingVideo != nil }, set: { if !$0 { deletingVideo = nil } })) {
            Button(L("移入废纸篓"), role: .destructive) {
                guard let url = deletingVideo else { return }
                do { try library.deleteVideo(url) }
                catch { model.errorMessage = error.localizedDescription }
                deletingVideo = nil
            }
        }
        .confirmationDialog(L("将这段录制移入系统废纸篓？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("移入废纸篓"), role: .destructive) {
                guard let session = deleting, model.exportingSessionID != session.id else { return }
                do { try library.deleteSession(session) }
                catch { model.errorMessage = error.localizedDescription }
                deleting = nil
            }
        }
    }

    private var filterControls: some View {
        let visible = visibleAssets
        let allSelected = !visible.isEmpty && selectedAssets == visible
        let sessions = sessionsByURL
        return HStack(spacing: 8) {
            VaultImageFilterControls(query: $query, collectionFilter: $collectionFilter,
                                     tagFilter: $tagFilter, sortOrder: $sortOrder)
            AssetScanMenu(model: model, assets: visibleURLs.map { url in
                sessions[url].map { .session($0.id) } ?? .video(url)
            }, selected: selectedAssets)
            Button {
                Task { await refreshRecordings() }
            } label: {
                Image(systemName: "arrow.clockwise").consoleFont(11)
                    .frame(width: 26 * max(1, fontScale), height: 28 * max(1, fontScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(refreshingFileInfo)
            .help(L("刷新录制列表与文件大小")).accessibilityLabel(L("刷新录制列表"))
            Spacer(minLength: 6)
            VaultDisplayModePicker(selection: $displayMode)
                .accessibilityIdentifier("recording-display-mode")
                .help(L("展示模式"))
            Text(L("\(visible.count) 段")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
                .help(L("\(library.videos.count) 段视频 · \(library.sessions.count) 段关键帧"))
            Button(allSelected ? L("取消") : L("全选")) {
                anchor = nil
                selected = allSelected ? [] : visible
            }
            .buttonStyle(.plain).consoleFont(11).foregroundStyle(Palette.accent).fixedSize()
            .disabled(visible.isEmpty)
            .help(L("选择当前列表的全部录制"))
        }
    }

    private var recordings: some View {
        let sessions = sessionsByURL
        let urls = visibleURLs
        return Group {
            if urls.isEmpty {
                if collectionFilter == .unfiled && tagFilter == .all && query.isEmpty {
                    Text(L("所有录制都已加入收藏夹，可切换到「全部」查看。"))
                        .foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    ContentUnavailableView(L("没有内容"), systemImage: "play.rectangle",
                                           description: Text(L("试试其他标签或搜索条件。")))
                        .padding(.vertical, 32)
                }
            } else {
                LazyVGrid(columns: columns, spacing: displayMode == .imagesOnly ? 3 : 16) {
                    ForEach(urls, id: \.self) { url in
                        let session = sessions[url]
                        let asset: CollectionAsset = session.map { .session($0.id) } ?? .video(url)
                        CollectionRecordingCard(library: library, session: session, videoURL: session == nil ? url : nil,
                                                thumbnailVersion: recordingThumbnailVersion,
                                                title: recordingTitle(url, session: session),
                                                detail: recordingDetail(url, session: session),
                                                fileInfo: fileInfo[url], tag: tag(for: url, session: session),
                                                selected: selected.contains(asset), displayMode: displayMode,
                                                collections: library.collections(containing: asset),
                                                toggle: { select(asset, modifiers: $0) }, open: { open(url, session: session) })
                            .accessibilityIdentifier("recording-\(displayMode.rawValue)-\(url.lastPathComponent)")
                            .contextMenu { contextMenu(url, session: session) }
                            .onDrag {
                                CollectionDrag.provider(assets: selectedAssets.contains(asset) ? selectedAssets : [asset])
                            } preview: {
                                CollectionDragPreview(title: recordingTitle(url, session: session),
                                                      count: selectedAssets.contains(asset) ? selectedAssets.count : 1,
                                                      symbol: "play.rectangle")
                            }
                    }
                }
                .accessibilityIdentifier("recordings-grid")
                .padding(.horizontal, displayMode == .imagesOnly ? 12 : 24)
            }
        }
    }

    private var selectionBar: some View {
        ViewThatFits(in: .horizontal) {
            selectionActions(compact: false)
            selectionActions(compact: true)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(minHeight: 54).fixedSize(horizontal: false, vertical: true)
        .background(Palette.background)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func selectionActions(compact: Bool) -> some View {
        let selection = selectedAssets
        let urls = visibleURLs
        let sessions = sessionsByURL
        let selectedURLs = urls.filter { url in
            selection.contains(sessions[url].map { .session($0.id) } ?? .video(url))
        }
        let renameAssets = selectedURLs.filter { sessions[$0] == nil }.map(CollectionAsset.video)
        let singleURL = selectedURLs.count == 1 ? selectedURLs.first : nil
        return HStack(spacing: 10) {
            Text(L("已选 \(selection.count)")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
                .accessibilityIdentifier("recording-selection-count")
                .help(L("单击选择 · ⌘ 点击切换选择 · ⇧ 点击选范围"))
            Spacer(minLength: 6)
            Menu {
                AddToCollectionMenu(library: library, assets: selection) { model.errorMessage = $0.localizedDescription }
            } label: {
                Label(L("收藏"), systemImage: "folder.badge.plus")
                    .consoleFont(12, weight: .medium)
                    .labelStyle(.iconOnly).menuLabel(minimumWidth: 0, padding: 4)
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            .help(L("将选中的录制加入收藏夹")).accessibilityLabel(L("加入收藏夹"))
            Menu {
                AssetTagActions(selected: Set(selectedURLs.map { tag(for: $0, session: sessions[$0]) })) { value in
                    setTag(value, directories: selectedURLs.map { sessions[$0] == nil ? $0.deletingLastPathComponent() : $0 })
                }
            } label: {
                Label(L("标签"), systemImage: "tag")
                    .consoleFont(12, weight: .medium)
                    .labelStyle(.iconOnly).menuLabel(minimumWidth: 0, padding: 4)
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(selection.isEmpty)
            .help(L("颜色标签")).accessibilityLabel(L("颜色标签"))
            if renameAssets.count == selection.count && BatchRenameRule.supports(renameAssets) {
                Button { model.prepareBatchRename(renameAssets) } label: {
                    if compact { Image(systemName: "pencil") }
                    else { Label(L("批量命名"), systemImage: "pencil") }
                }.buttonStyle(QuietButtonStyle()).disabled(model.isExporting).fixedSize()
                    .help(L("批量命名")).accessibilityLabel(L("批量命名"))
            }
            if let url = singleURL {
                let session = sessions[url]
                if let session {
                    Menu { sessionExportActions(session) } label: {
                        Label(L("导出"), systemImage: "square.and.arrow.up")
                            .consoleFont(12, weight: .medium).menuLabel()
                    }.menuStyle(.borderlessButton).fixedSize().disabled(model.isExporting)
                }
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(QuietButtonStyle()).help(L("在 Finder 中显示"))
                    .accessibilityLabel(L("在 Finder 中显示"))
                Button { requestDeletion(url, session: session) } label: {
                    if compact { Image(systemName: "trash") }
                    else { Label(L("移入废纸篓"), systemImage: "trash") }
                }.buttonStyle(QuietButtonStyle()).fixedSize()
                    .help(L("移入废纸篓")).accessibilityLabel(L("移入废纸篓"))
                    .disabled(session.map { model.exportingSessionID == $0.id } == true)
                Button { open(url, session: session) } label: { Label(L("播放"), systemImage: "play.fill") }
                    .buttonStyle(AccentButtonStyle()).fixedSize()
            }
        }
    }

    @ViewBuilder private func contextMenu(_ url: URL, session: SavedSession?) -> some View {
        let asset: CollectionAsset = session.map { .session($0.id) } ?? .video(url)
        Button(L("播放")) { open(url, session: session) }
        if let session {
            Menu(L("导出")) { sessionExportActions(session) }.disabled(model.isExporting)
        }
        Menu(L("颜色标签")) {
            AssetTagActions(selected: [tag(for: url, session: session)]) {
                setTag($0, directories: [session == nil ? url.deletingLastPathComponent() : url])
            }
        }
        Menu(L("加入收藏夹")) {
            AddToCollectionMenu(library: library, assets: [asset]) { model.errorMessage = $0.localizedDescription }
        }
        Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        Divider()
        Button(L("移入废纸篓"), role: .destructive) { requestDeletion(url, session: session) }
            .disabled(session.map { model.exportingSessionID == $0.id } == true)
    }

    @ViewBuilder private func sessionExportActions(_ session: SavedSession) -> some View {
        Button(L("导出 MP4 视频…")) { model.exportSession(session, format: .mp4) }
        Button(L("导出 GIF 动图…")) { model.exportSession(session, format: .gif) }
        Divider()
        Button(L("导出到保管箱")) { model.exportSessionToVault(session) }
    }

    private func select(_ asset: CollectionAsset, modifiers: NSEvent.ModifierFlags) {
        NSApp.currentEvent?.window?.makeFirstResponder(nil)
        let sessions = sessionsByURL
        let ordered = visibleURLs.map { url in
            sessions[url].map { CollectionAsset.session($0.id) } ?? .video(url)
        }
        selected = VaultSelection.select(asset, in: ordered, modifiers: modifiers, anchor: &anchor, selected: selected)
    }

    private func recordingTitle(_ url: URL, session: SavedSession?) -> String {
        session.map { $0.manifest.name ?? $0.manifest.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale)) }
            ?? url.deletingPathExtension().lastPathComponent
    }

    private func recordingDetail(_ url: URL, session: SavedSession?) -> String {
        if let session {
            return L("\(session.manifest.frames.count) 个关键帧  ·  \(Self.time(session.manifest.duration))  ·  \(session.manifest.width) × \(session.manifest.height)")
        }
        if let date = creationDates[url] {
            return L("MP4 视频") + " · " + date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale))
        }
        return L("MP4 视频")
    }

    private func tag(for url: URL, session: SavedSession?) -> AssetTag? {
        library.recordingTags[session == nil ? url.deletingLastPathComponent() : url]
    }

    private func open(_ url: URL, session: SavedSession?) {
        let target = session == nil ? url : url.appendingPathComponent("player.html")
        guard NSWorkspace.shared.open(target) else {
            model.errorMessage = session == nil ? L("无法打开视频，请检查系统默认视频播放器。")
                : L("无法打开关键帧播放器，请检查录制文件是否可访问，以及系统默认浏览器。")
            return
        }
    }

    private func requestDeletion(_ url: URL, session: SavedSession?) {
        if let session { deleting = session }
        else { deletingVideo = url }
    }

    private func setTag(_ tag: AssetTag?, directories: [URL]) {
        do {
            for directory in directories { try library.setRecordingTag(tag, for: directory) }
            let sessions = Set(library.sessions.map(\.directory))
            let changedSessions = directories.filter { sessions.contains($0) }
            if !changedSessions.isEmpty { Task { await refreshFileInfo(for: changedSessions) } }
        }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func refreshFileInfo(for changedURLs: [URL]) async {
        let urls = recordingURLs
        await fileInfoLoader.invalidate(changedURLs)
        do {
            let result = try await fileInfoLoader.load(urls, includingCreationDates: true)
            let dates = await fileInfoLoader.creationDates
            try Task.checkCancellation()
            if urls == recordingURLs { fileInfo = result; creationDates = dates }
        } catch is CancellationError {
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func refreshRecordings() async {
        refreshingFileInfo = true
        defer { refreshingFileInfo = false }
        do {
            try library.reloadSessions()
            let urls = recordingURLs
            await fileInfoLoader.invalidate(urls)
            let result = try await fileInfoLoader.load(urls, includingCreationDates: true)
            let dates = await fileInfoLoader.creationDates
            try Task.checkCancellation()
            if urls == recordingURLs { fileInfo = result; creationDates = dates }
        } catch is CancellationError {
        } catch { model.errorMessage = error.localizedDescription }
    }

    private var exportStatus: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("正在导出 \(model.exportFilename)"))
                    .consoleFont(12, weight: .medium).lineLimit(1).truncationMode(.middle)
                if model.exportIsIndeterminate {
                    ProgressView().controlSize(.small)
                } else {
                    ProgressView(value: model.exportProgress).tint(Palette.accent)
                }
            }
            if !model.exportIsIndeterminate {
                Text(model.exportProgress, format: .percent.precision(.fractionLength(0)))
                    .consoleFont(11, design: .monospaced).foregroundStyle(Palette.muted).frame(width: 40 * fontScale)
            }
            Button(L("取消")) { model.cancelExport() }.buttonStyle(QuietButtonStyle())
        }.padding(14).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
    }

    static func time(_ duration: Double) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct RecordingStatusView: View {
    @ObservedObject var recorder: KeyframeRecorder
    let region: RecordingRegion?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill")
                .foregroundStyle(recorder.isPaused ? Color.orange : Color.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(recorder.isPaused ? L("已暂停") : recorder.mode == .video ? L("正在录制视频") : L("正在记录关键帧"))
                    .consoleFont(12, weight: .medium)
                if let region {
                    Text("\(Double(region.rect.width).formatted(.number.precision(.fractionLength(0...2)))) × \(Double(region.rect.height).formatted(.number.precision(.fractionLength(0...2)))) pt")
                        .consoleFont(11, design: .monospaced).foregroundStyle(Palette.muted)
                }
            }
            Spacer()
            Text(RecordingView.time(recorder.elapsed)).consoleFont(13, design: .monospaced)
                .monospacedDigit()
            if recorder.mode == .keyframes {
                Text(L("\(recorder.frameCount) 个关键帧")).consoleFont(12).foregroundStyle(Palette.muted)
            }
        }.padding(.horizontal, 2)
    }
}

struct GuideView: View {
    @Environment(\.consoleFontScale) private var fontScale
    @ObservedObject var model: AppModel
    @State private var activeAnimation: GuideAnimation?
    @State private var hoveredAnimation: GuideAnimation?
    @State private var applicationActive = NSApplication.shared.isActive

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L("鼠标移到说明行即可播放右侧演示，移开暂停。演示使用默认配色与快捷键，界面为简体中文。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                    guideSection(L("截图与贴图")) {
                        guideRow(.captureRegion, viewport: geometry.size) {
                            VStack(alignment: .leading, spacing: 10) {
                                shortcut(L("截取区域"), action: .captureRegion, detail: L("框选后可原地调整范围，添加矩形、箭头、画笔或文字。浮动条可复制图片、保存或固定贴图；非文字输入时按 Enter / 双击完成，Esc 取消。"))
                                Text(L("文字工具：点击选区输入，支持中文、多行、颜色与字号。Enter 换行，⌘Enter 完成文字，Esc 取消当前输入。"))
                            }
                        }
                        guideRow(.pinMoveScale, viewport: geometry.size) {
                            shortcut(L("贴出最近图片"), action: .pinLatest, detail: L("贴图始终置顶；拖动移动，滚轮缩放，双击或 Esc 关闭。"))
                        }
                    }
                    guideSection(L("快捷键")) {
                        Text(L("在侧栏「快捷键设置」或菜单「快捷键设置…」中修改。点击录入框后按功能键或组合键；Esc 取消，Delete 或清除按钮移除绑定。录入期间全局快捷键暂时暂停。"))
                        Button(L("前往快捷键设置")) { model.section = .shortcuts }.buttonStyle(QuietButtonStyle())
                        Text(L("菜单中的「禁用快捷键」暂停所有绑定并保留配置。Mac 的功能键可能需要同时按 Fn / 🌐，也可在系统键盘设置中将 F1、F2 等设为标准功能键。"))
                    }
                    guideSection(L("拼图")) {
                        guideAnimation(.collageReorder, detail: L("单击图片仅选中一张，按住 ⌘ 点击可多选，再点「Grid / 自由拼图」。Grid 可指定行列，拖动顶部缩略图调整拼图顺序。"), viewport: geometry.size)
                        guideAnimation(.freeformMoveResize, detail: L("自由拼图关闭「开启一键拼」后，可在画布拖动、缩放和叠放单张图片；拖动四角等比调整。"), viewport: geometry.size)
                        Text(L("可设置缩放比、单张图片最大宽高和间距。「全屏预览」查看完整大图，支持适应屏幕、原始像素与缩放；Esc 返回。结果可直接拷贝图片、存入保管箱或导出 PNG。"))
                    }
                    guideSection(L("收藏夹")) {
                        guideAnimation(.collectionReorder, detail: L("点击侧栏「收藏夹」旁的 ＋ 新建；收藏夹平级展示，右键可重命名或删除。将收藏夹拖到行间或列表末尾调整顺序，右键也可上移、下移。"), viewport: geometry.size)
                        guideAnimation(.dragToCollection, detail: L("图片和录屏可通过「加入收藏夹」菜单批量归类，也可拖到侧栏。同一内容可加入多个收藏夹，共用原文件；移除内容或删除收藏夹只取消归类，不删除文件。"), viewport: geometry.size)
                        Text(L("保管箱与录屏列表可切换「全部 / 未归类」。加入收藏夹后会从未归类列表消失；全部列表仍保留，并显示所属收藏夹。"))
                        Text(L("点击收藏夹查看混合内容，可搜索、按标签筛选、按时间或大小排序。选中图片后可直接拼图；关键帧录制可先选帧再拼图。拼图结果保存时同时加入来源收藏夹。"))
                    }
                    guideSection(L("图像处理")) {
                        guideAnimation(.squareCropGrid, detail: L("宫格切图先裁出正方形：拖动选框移动，拖动角点等比调整，也可输入宽高。下一步选择 4 / 9 宫格、单片尺寸和跳过间隙，再导出。间隙处的原图像素会被裁掉。"), viewport: geometry.size)
                    }
                    guideSection(L("控制台")) {
                        guideAnimation(.sidebarResize, detail: L("拖动侧栏与内容之间的分隔线调整宽度，松开后保留设置。"), viewport: geometry.size)
                    }
                    guideSection(L("录屏与导出")) {
                        Text(L("录屏不支持录音，主要用于后续按帧截取图片。"))
                        shortcut(L("开始 / 停止录屏"), action: .toggleRecording, detail: L("按所选方式直接录为 MP4，或保存关键帧幻灯片。框选并调整范围后点击开始，Esc 取消选区。绿框标记录制区域，浮动条可暂停、继续或停止；也可再次按快捷键停止。暂停不计时、不保存画面。"))
                        Text(L("在关键帧档案中点击「导出」，选择 MP4、GIF 或「导出到保管箱」。入箱时按时间顺序保存原始 PNG 并继承颜色标签，可继续多选拼图；原录制保留。MP4 和 GIF 保留实际停留时间，最长边分别为 1920 px、1280 px，只缩小较大画面；导出时可查看进度或取消。"))
                        Text(L("录屏排除 Clipato 窗口和绿色边框。关键帧用于变化较少的内容，采样间隔内的快速动画可能略过。"))
                    }
                    guideSection(L("首次使用")) {
                        Text(L("截图与录屏需要屏幕录制权限，不采集系统音频或麦克风。系统请求时允许 Clipato；如果系统要求重启应用，退出后重新打开。全局快捷键无需辅助功能权限。"))
                        Button(L("打开屏幕录制权限设置")) { model.openScreenPermissions() }.buttonStyle(QuietButtonStyle())
                    }
                    if !DistributionChannel.isAppStore {
                        guideSection(L("命令行")) {
                            Text(L("App 内置命令行工具，可查看截图、录屏、拼图、导出与保管箱命令。命令行与 App 使用同一个本地保管箱。"))
                            Button(L("复制命令行帮助命令")) {
                                let path = Bundle.main.executableURL!.path.replacingOccurrences(of: "'", with: "'\\''")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("'\(path)' --help", forType: .string)
                            }.buttonStyle(QuietButtonStyle())
                        }
                    }
                    Text(L("\(AppVersion.displayName) · macOS 14+ · 数据保存在本机\n截图、录屏完成后不会自动打开控制台；请从状态栏菜单打开。\n跨屏选区、OCR 与音频录制暂未加入。"))
                        .consoleFont(11).foregroundStyle(Palette.muted).lineSpacing(4)
                }.padding(24).frame(maxWidth: 960, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "guide-viewport")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
    }

    private func guideRow<Content: View>(_ animation: GuideAnimation, viewport: CGSize,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        GuideAnimationRow(animation: animation, active: $activeAnimation, hovered: $hoveredAnimation,
                          viewport: viewport, applicationActive: applicationActive, content: content)
    }

    private func guideAnimation(_ animation: GuideAnimation, detail: String, viewport: CGSize) -> some View {
        guideRow(animation, viewport: viewport) {
            VStack(alignment: .leading, spacing: 6) {
                Text(animation.title).consoleFont(12, weight: .medium).foregroundStyle(Palette.foreground)
                Text(detail)
            }
        }
    }

    private func shortcut(_ title: String, action: ShortcutAction, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ShortcutLabel(shortcuts: model.shortcuts, action: action)
                .consoleFont(12, weight: .medium, design: .monospaced)
                .foregroundStyle(Palette.foreground).frame(width: 76 * fontScale, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).consoleFont(12, weight: .medium).foregroundStyle(Palette.foreground)
                Text(detail)
            }
            Spacer(minLength: 0)
        }
    }

    private func guideSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).consoleFont(13, weight: .semibold).foregroundStyle(Palette.foreground)
            content().consoleFont(12).foregroundStyle(Palette.muted).lineSpacing(4)
            Divider().overlay(Palette.line).padding(.top, 6)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
