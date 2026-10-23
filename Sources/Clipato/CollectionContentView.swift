import AppKit
import SwiftUI

struct CollectionContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    let collectionID: UUID
    @Environment(\.consoleFontScale) private var fontScale
    @AppStorage("collectionDisplayMode") private var displayMode = VaultDisplayMode.imagesOnly
    @State private var query = ""
    @State private var tagFilter = AssetTagFilter.all
    @State private var sortOrder = AssetSortOrder.newest
    @State private var selected: Set<CollectionAsset> = []
    @State private var anchor: CollectionAsset?
    @State private var images: [UUID: VaultImage] = [:]
    @State private var sessions: [UUID: SavedSession] = [:]
    @State private var visibleAssets: [CollectionAsset] = []
    @State private var assetURLs: [URL] = []
    @State private var unavailableCount = 0
    @State private var fileInfo: [URL: AssetFileInfo] = [:]
    @State private var creationDates: [URL: Date] = [:]
    @State private var fileInfoLoader = AssetFileInfoLoader()
    @State private var refreshing = false
    @State private var pickingFrames: SavedSession?
    @State private var pendingFrames: (session: SavedSession, indices: [Int], longScreenshot: Bool)?
    @State private var preparingFrames: Task<Void, Never>?
    @State private var recentlySelectedID: UUID?
    @State private var previewedID: UUID?
    @State private var recordingThumbnailVersion = 0

    private var columns: [GridItem] {
        let scale = max(1, fontScale)
        if displayMode == .imagesOnly {
            return [GridItem(.adaptive(minimum: 150 * scale, maximum: 220 * scale), spacing: 3)]
        }
        return [GridItem(.adaptive(minimum: 215 * scale, maximum: 330 * scale), spacing: 16)]
    }
    private var selectedImages: [VaultImage] {
        visibleAssets.compactMap { asset in
            guard selected.contains(asset), case .image(let id) = asset else { return nil }
            return images[id]
        }
    }
    private var selectedSession: SavedSession? {
        guard selected.count == 1, let asset = selected.first, case .session(let id) = asset else { return nil }
        return sessions[id]
    }
    private var directSelection: Set<CollectionAsset> {
        selected.intersection(library.collectionMembers[collectionID, default: []])
    }
    private var selectedImageIDs: Set<UUID> {
        Set(selected.compactMap { if case .image(let id) = $0 { return id }; return nil })
    }

    private var content: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                filterControls
                ScrollView(.horizontal) { filterControls.fixedSize(horizontal: true, vertical: false) }
                    .scrollIndicators(.hidden)
            }.frame(height: 28 * max(1, fontScale)).padding(.horizontal, 24).padding(.vertical, 10)
            if unavailableCount > 0 {
                Label(L("\(unavailableCount) 项暂不可用；连接对应磁盘后刷新列表。"), systemImage: "externaldrive.badge.exclamationmark")
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 10)
            }
            if visibleAssets.isEmpty {
                ContentUnavailableView(unavailableCount > 0 ? L("内容暂不可用") : L("没有内容"), systemImage: "folder", description: Text(
                    unavailableCount > 0 ? L("收藏关系仍然保留。")
                    : assetURLs.isEmpty ? L("将图片或录屏拖到侧栏收藏夹，也可以从列表菜单批量加入。")
                    : L("试试其他标签或搜索条件。")))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: displayMode == .imagesOnly ? 3 : 16) {
                        ForEach(visibleAssets, id: \.self) { asset in
                            card(for: asset)
                                .contextMenu { contextMenu(for: asset) }
                                .onDrag {
                                    CollectionDrag.provider(assets: selected.contains(asset) ? selected : [asset])
                                } preview: {
                                    CollectionDragPreview(title: L("收藏内容"), count: selected.contains(asset) ? selected.count : 1,
                                                          symbol: "square.stack")
                                }
                        }
                    }.padding(.horizontal, displayMode == .imagesOnly ? 12 : 24)
                        .padding(.bottom, displayMode == .imagesOnly ? 12 : 20)
                }
            }
            selectionBar
        }
    }

    private var observedContent: some View {
        content
            .background(SystemImagePreview(url: previewURL, urls: previewURLs))
            .onChange(of: library.images) { previous, current in
                let renames = renamedImageURLs(previous: previous, current: current, imageURL: library.imageURL)
                fileInfo = remappingAssetMetadata(fileInfo, renames: renames)
                rebuildAssets()
            }
            .onChange(of: library.sessions.map(\.id)) { _, _ in rebuildAssets() }
            .onChange(of: library.videos) { _, _ in rebuildAssets() }
            .onChange(of: library.collectionMembers) { _, _ in rebuildAssets() }
            .onChange(of: library.collections) { _, _ in rebuildAssets() }
            .onChange(of: library.recordingTags) { _, _ in updateVisibleAssets() }
            .onChange(of: query) { _, _ in updateVisibleAssets() }
            .onChange(of: tagFilter) { _, _ in updateVisibleAssets() }
            .onChange(of: sortOrder) { _, _ in updateVisibleAssets() }
            .onChange(of: fileInfo) { _, _ in updateVisibleAssets() }
            .onChange(of: creationDates) { _, _ in updateVisibleAssets() }
            .task(id: assetURLs) { await loadFileInfo(refresh: false) }
    }

    var body: some View {
        observedContent
        .onReceive(NotificationCenter.default.publisher(for: .clipatoSelectAllVisibleAssets, object: model)) { _ in
            anchor = nil
            setSelection(Set(visibleAssets))
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipatoPreviewSelectedImage, object: model)) { _ in
            previewSelectedImage()
        }
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
            setSelection(Set(selected.map { changes[$0] ?? $0 }))
        }
        .onAppear { model.selected = []; rebuildAssets() }
        .onDisappear {
            preparingFrames?.cancel()
            preparingFrames = nil
            previewedID = nil
            recentlySelectedID = nil
            if model.selected == selectedImageIDs { model.selected = [] }
        }
        .onChange(of: selected) { _, selection in
            if let previewedID, !selection.contains(.image(previewedID)) { self.previewedID = nil }
        }
        .onChange(of: visibleAssets) { _, assets in
            if let previewedID, !assets.contains(.image(previewedID)) { self.previewedID = nil }
        }
        .onChange(of: displayMode) { _, _ in previewedID = nil }
        .onChange(of: model.selected) { _, _ in
            if selectedImageIDs != model.selected { rebuildAssets() }
        }
        .sheet(item: $pickingFrames, onDismiss: composePendingFrames) { session in
            KeyframePickerView(session: session, library: library) { indices, longScreenshot in
                pendingFrames = (session, indices, longScreenshot)
                pickingFrames = nil
            }
        }
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(L("搜索"), text: $query).textFieldStyle(.plain).consoleFont(12)
                    .environment(\.isFocusEffectEnabled, true).accessibilityLabel(L("搜索收藏夹"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }.padding(.horizontal, 8).frame(height: 28 * max(1, fontScale))
                .frame(minWidth: 90 * max(1, fontScale), maxWidth: 180 * max(1, fontScale))
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                .overlay { SurfaceBorder(cornerRadius: 6) }
            AssetTagFilterPicker(selection: $tagFilter)
            AssetSortPicker(selection: $sortOrder)
            AssetScanMenu(model: model, assets: visibleAssets, selected: selected)
            Button {
                Task { await loadFileInfo(refresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise").consoleFont(11)
                    .frame(width: 26 * max(1, fontScale), height: 28 * max(1, fontScale)).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(refreshing).help(L("刷新文件大小")).accessibilityLabel(L("刷新文件大小"))
            Spacer(minLength: 6)
            Menu {
                Picker(L("展示模式"), selection: $displayMode) {
                    Label(L("概览"), systemImage: VaultDisplayMode.imagesOnly.symbol).tag(VaultDisplayMode.imagesOnly)
                    Label(L("卡片"), systemImage: VaultDisplayMode.standard.symbol).tag(VaultDisplayMode.standard)
                }.pickerStyle(.inline)
            } label: {
                Label(displayMode.title, systemImage: displayMode.symbol)
                    .consoleFont(11).menuLabel(minimumWidth: 0, padding: 4)
            }
            .menuStyle(.borderlessButton).fixedSize().help(L("展示模式"))
            .accessibilityLabel(L("展示模式")).accessibilityValue(displayMode.title)
            Text(L("\(visibleAssets.count) 项")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
            Button(!visibleAssets.isEmpty && selected.count == visibleAssets.count ? L("取消") : L("全选")) {
                anchor = nil
                setSelection(selected.count == visibleAssets.count ? [] : Set(visibleAssets))
            }.buttonStyle(.plain).consoleFont(11).foregroundStyle(Palette.accent).fixedSize()
        }
    }

    @ViewBuilder private func card(for asset: CollectionAsset) -> some View {
        switch asset {
        case .image(let id):
            if let item = images[id] {
                ImageCard(item: item, library: library, fileInfo: fileInfo[library.imageURL(item)],
                          collections: library.collections(containing: asset),
                          selected: selected.contains(asset), displayMode: displayMode,
                          toggle: { select(asset, modifiers: $0) },
                          edit: { if !model.preparingCollectionFrames { model.edit(item) } },
                          preview: { previewImage(id) })
            }
        case .session(let id):
            if let session = sessions[id] {
                CollectionRecordingCard(library: library, session: session,
                                        title: session.manifest.name ?? session.manifest.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale)),
                                        detail: L("关键帧 · \(session.manifest.frames.count) 帧"),
                                        fileInfo: fileInfo[session.directory], tag: tag(for: asset), selected: selected.contains(asset),
                                        displayMode: displayMode, collections: library.collections(containing: asset),
                                        toggle: { select(asset, modifiers: $0) }, open: { open(asset) })
            }
        case .video(let url):
            CollectionRecordingCard(library: library, session: nil, videoURL: url,
                                    thumbnailVersion: recordingThumbnailVersion,
                                    title: url.deletingPathExtension().lastPathComponent, detail: L("完整视频 · MP4"),
                                    fileInfo: fileInfo[url], tag: tag(for: asset), selected: selected.contains(asset),
                                    displayMode: displayMode, collections: library.collections(containing: asset),
                                    toggle: { select(asset, modifiers: $0) }, open: { open(asset) })
        }
    }

    @ViewBuilder private func contextMenu(for asset: CollectionAsset) -> some View {
        switch asset {
        case .image(let id):
            if let image = images[id] {
                Button(L("预览")) { previewImage(id) }
                Button(L("编辑标注")) { model.edit(image) }
                    .disabled(model.preparingCollectionFrames)
                Button(L("宫格切图…")) { model.prepareImageExport([image], mode: .files, tool: .grid) }
                    .disabled(model.isExporting || model.preparingCollectionFrames)
                Button(L("浮窗贴图")) { model.pin(image) }
                Button(L("复制图片")) { model.copy(image) }
            }
        case .session(let id):
            if let session = sessions[id] {
                Button(L("播放")) { open(asset) }
                Button(L("选择关键帧拼图…")) { pickingFrames = session }
                    .disabled(model.preparingCollectionFrames)
                Menu(L("导出")) {
                    Button(L("MP4 视频…")) { model.exportSession(session, format: .mp4) }
                    Button(L("GIF 动图…")) { model.exportSession(session, format: .gif) }
                    Button(L("导出到保管箱")) { model.exportSessionToVault(session) }
                }.disabled(model.isExporting || model.preparingCollectionFrames)
            }
        case .video:
            Button(L("播放")) { open(asset) }
        }
        Menu(L("颜色标签")) { AssetTagActions(selected: [tag(for: asset)]) { setTag($0, assets: [asset]) } }
        Menu(L("加入收藏夹")) {
            AddToCollectionMenu(library: library, assets: [asset], onError: { model.errorMessage = $0.localizedDescription })
        }
        Button(L("在 Finder 中显示")) {
            if let url = url(for: asset) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        Button(L("从当前收藏夹移除")) { remove([asset]) }
            .disabled(!library.collectionMembers[collectionID, default: []].contains(asset))
    }

    private var selectionBar: some View {
        ViewThatFits(in: .horizontal) {
            selectionControls(compact: false)
            selectionControls(compact: true)
        }.padding(.horizontal, 24).padding(.vertical, 12)
            .frame(minHeight: 54).fixedSize(horizontal: false, vertical: true)
            .background(Palette.background)
            .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func selectionControls(compact: Bool) -> some View {
        let items = selectedImages
        let renameAssets = visibleAssets.filter { selected.contains($0) }
        return HStack(spacing: 10) {
            Text(L("已选 \(selected.count) 项")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
                .help(L("单击选择 · ⌘ 点击切换选择 · ⇧ 点击选范围 · ⌘A 全选 · 拖到侧栏加入其他收藏夹"))
            if model.preparingCollectionFrames {
                ProgressView().controlSize(.small).help(L("正在读取选中的关键帧"))
            }
            Spacer(minLength: 6)
            Menu {
                Menu(L("加入收藏夹")) {
                    AddToCollectionMenu(library: library, assets: selected, onError: { model.errorMessage = $0.localizedDescription })
                }
                Menu(L("颜色标签")) { AssetTagActions(selected: Set(selected.map { tag(for: $0) })) { setTag($0, assets: selected) } }
                if BatchRenameRule.supports(renameAssets) {
                    Button(L("批量命名…")) { model.prepareBatchRename(renameAssets) }
                        .disabled(model.isExporting)
                }
                Divider()
                Button(L("从当前收藏夹移除 · \(directSelection.count) 项")) { remove(directSelection) }
                    .disabled(directSelection.isEmpty)
            } label: {
                Label(L("整理"), systemImage: "folder").consoleFont(12, weight: .medium).menuLabel()
            }.menuStyle(.borderlessButton).fixedSize().disabled(selected.isEmpty)
            if let session = selectedSession {
                Button { pickingFrames = session } label: { Label(L("选择关键帧"), systemImage: "rectangle.stack") }
                    .buttonStyle(AccentButtonStyle()).disabled(model.preparingCollectionFrames).fixedSize()
            } else if !items.isEmpty && items.count == selected.count {
                Menu {
                    Button(L("图片 / PDF…")) { model.prepareImageExport(items, mode: .files) }
                    Button(L("ZIP 压缩包…")) { model.prepareImageExport(items, mode: .zip) }
                    Button("MP4 / GIF…") { model.prepareImageExport(items, mode: .video) }
                    Divider()
                    Button(L("压缩体积…")) { model.prepareImageExport(items, mode: .files, tool: .compress) }
                    Button(L("调整尺寸…")) { model.prepareImageExport(items, mode: .files, tool: .resize) }
                    Button(L("转换格式…")) { model.prepareImageExport(items, mode: .files, tool: .convert) }
                } label: {
                    Label(compact ? L("导出") : L("导出图片"), systemImage: "square.and.arrow.up")
                        .consoleFont(12, weight: .medium).menuLabel()
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.isExporting || model.preparingCollectionFrames)
                Button { model.composeLongScreenshot(images: items, collectionID: collectionID) } label: {
                    Label(compact ? L("长图") : L("长图拼接"), systemImage: "rectangle.portrait")
                }.buttonStyle(QuietButtonStyle())
                    .disabled(!model.hasCollageWorkspace && (model.preparingCollectionFrames || model.fixedCaptureRegion != nil || model.capturing)).fixedSize()
                Button { model.compose(images: items, collectionID: collectionID) } label: {
                    Label(L("拼图 · \(items.count) 张"), systemImage: "square.grid.2x2")
                }.buttonStyle(AccentButtonStyle())
                    .disabled(!model.hasCollageWorkspace && (model.preparingCollectionFrames || model.fixedCaptureRegion != nil || model.capturing)).fixedSize()
            }
        }
    }

    private func rebuildAssets() {
        images = Dictionary(uniqueKeysWithValues: library.images.map { ($0.id, $0) })
        sessions = Dictionary(uniqueKeysWithValues: library.sessions.map { ($0.id, $0) })
        let members = library.assets(in: collectionID)
        let ordered = library.images.map { CollectionAsset.image($0.id) }
            + library.sessions.map { CollectionAsset.session($0.id) } + library.videos.map(CollectionAsset.video)
        assetURLs = ordered.filter { members.contains($0) }.compactMap { url(for: $0) }
        unavailableCount = members.subtracting(ordered).count
        updateVisibleAssets()
    }

    private func updateVisibleAssets() {
        let members = library.assets(in: collectionID)
        let ordered = library.images.map { CollectionAsset.image($0.id) }
            + library.sessions.map { CollectionAsset.session($0.id) } + library.videos.map(CollectionAsset.video)
        let matching = ordered.filter { members.contains($0) && tagFilter.includes(tag(for: $0)) && matchesQuery($0) }
        visibleAssets = sortOrder.sorted(matching, date: { date(for: $0) }, size: { asset in
            url(for: asset).flatMap { fileInfo[$0]?.byteCount }
        }, name: { name(for: $0) })
        let recordings = selected.filter { if case .image = $0 { return false }; return true }
        let selection = Set(model.selected.map(CollectionAsset.image)).union(recordings)
        setSelection(selection.intersection(Set(visibleAssets)))
        anchor = nil
    }

    private func url(for asset: CollectionAsset) -> URL? {
        switch asset {
        case .image(let id): return images[id].map(library.imageURL)
        case .session(let id): return sessions[id]?.directory
        case .video(let url): return url
        }
    }

    private func tag(for asset: CollectionAsset) -> AssetTag? {
        switch asset {
        case .image(let id): return images[id]?.tag
        case .session(let id): return sessions[id].flatMap { library.recordingTags[$0.directory] }
        case .video(let url): return library.recordingTags[url.deletingLastPathComponent()]
        }
    }

    private func name(for asset: CollectionAsset) -> String {
        switch asset {
        case .image(let id): return images[id]!.filename
        case .session(let id): return sessions[id]!.manifest.name ?? sessions[id]!.directory.lastPathComponent
        case .video(let url): return url.lastPathComponent
        }
    }

    private func date(for asset: CollectionAsset) -> Date? {
        switch asset {
        case .image(let id): return images[id]?.createdAt
        case .session(let id): return sessions[id]?.manifest.createdAt
        case .video(let url): return creationDates[url]
        }
    }

    private func matchesQuery(_ asset: CollectionAsset) -> Bool {
        guard !query.isEmpty else { return true }
        switch asset {
        case .image(let id):
            guard let image = images[id] else { return false }
            return image.filename.localizedCaseInsensitiveContains(query) || image.source.localizedCaseInsensitiveContains(query)
        case .session(let id):
            guard let session = sessions[id] else { return false }
            return L("关键帧").localizedCaseInsensitiveContains(query)
                || session.manifest.name?.localizedCaseInsensitiveContains(query) == true
                || session.directory.lastPathComponent.localizedCaseInsensitiveContains(query)
                || session.manifest.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(LanguageSettings.shared.locale)).localizedCaseInsensitiveContains(query)
        case .video(let url):
            return url.lastPathComponent.localizedCaseInsensitiveContains(query) || L("完整视频").localizedCaseInsensitiveContains(query)
        }
    }

    private func select(_ asset: CollectionAsset, modifiers: NSEvent.ModifierFlags) {
        NSApp.currentEvent?.window?.makeFirstResponder(nil)
        setSelection(VaultSelection.select(asset, in: visibleAssets, modifiers: modifiers, anchor: &anchor, selected: selected))
        if case .image(let id) = asset {
            recentlySelectedID = selected.contains(asset) ? id : nil
        }
    }

    private var previewURLs: [URL] {
        visibleAssets.compactMap { asset in
            guard case .image(let id) = asset, let item = images[id] else { return nil }
            return library.imageURL(item)
        }
    }

    private var previewURL: Binding<URL?> {
        Binding(get: {
            guard let previewedID, let item = library.images.first(where: { $0.id == previewedID }) else { return nil }
            return library.imageURL(item)
        }, set: { url in
            guard let url else { previewedID = nil; return }
            for case .image(let id) in visibleAssets {
                guard let item = images[id], library.imageURL(item) == url else { continue }
                previewImage(id)
                return
            }
        })
    }

    private func previewImage(_ id: UUID) {
        setSelection([.image(id)])
        anchor = .image(id)
        recentlySelectedID = id
        previewedID = id
    }

    private func previewSelectedImage() {
        let ids = visibleAssets.compactMap { asset -> UUID? in
            if case .image(let id) = asset { return id }
            return nil
        }
        guard let id = VaultSelection.previewID(in: ids, selected: selectedImageIDs,
                                                preferredID: recentlySelectedID) else { return }
        previewedID = previewedID == id ? nil : id
    }

    private func setSelection(_ selection: Set<CollectionAsset>) {
        selected = selection
        let ids = selectedImageIDs
        if model.selected != ids { model.selected = ids }
    }

    private func remove(_ assets: Set<CollectionAsset>) {
        do { try library.removeFromCollection(collectionID, assets: assets) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func setTag(_ tag: AssetTag?, assets: Set<CollectionAsset>) {
        do {
            let imageItems = assets.compactMap { asset -> VaultImage? in
                guard case .image(let id) = asset else { return nil }
                return images[id]
            }
            if !imageItems.isEmpty { try library.setTag(tag, for: imageItems) }
            for asset in assets {
                switch asset {
                case .image: break
                case .session(let id):
                    if let session = sessions[id] { try library.setRecordingTag(tag, for: session.directory) }
                case .video(let url): try library.setRecordingTag(tag, for: url.deletingLastPathComponent())
                }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func open(_ asset: CollectionAsset) {
        let target: URL?
        switch asset {
        case .image(let id):
            if let image = images[id] { model.edit(image) }
            return
        case .session(let id): target = sessions[id]?.directory.appendingPathComponent("player.html")
        case .video(let url): target = url
        }
        if let target, !NSWorkspace.shared.open(target) { model.errorMessage = L("无法打开录制，请检查文件和系统默认播放器。") }
    }

    private func loadFileInfo(refresh: Bool) async {
        refreshing = true
        defer { refreshing = false }
        do {
            if refresh {
                try library.reloadImages()
                try library.reloadSessions()
                rebuildAssets()
            }
            let urls = assetURLs
            if refresh { await fileInfoLoader.invalidate(urls) }
            let info = try await fileInfoLoader.load(urls, includingCreationDates: true)
            let dates = await fileInfoLoader.creationDates
            try Task.checkCancellation()
            guard urls == assetURLs else { return }
            fileInfo = info
            creationDates = dates
        } catch is CancellationError {
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func composePendingFrames() {
        guard let pending = pendingFrames else { return }
        pendingFrames = nil
        preparingFrames = Task {
            _ = await model.composeKeyframes(pending.session, indices: pending.indices,
                                             collectionID: collectionID, longScreenshot: pending.longScreenshot)
            preparingFrames = nil
        }
    }
}

