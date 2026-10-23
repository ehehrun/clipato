import SwiftUI
import AppKit

enum VaultDisplayMode: String {
    case standard, imagesOnly

    var title: String { self == .standard ? L("卡片") : L("概览") }
    var symbol: String { self == .standard ? "rectangle.grid.2x2" : "square.grid.2x2" }
}

struct VaultView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale
    @State private var confirmDelete = false
    @State private var selection = VaultSelection()
    @State private var tagFilter = AssetTagFilter.all
    @State private var sortOrder = AssetSortOrder.newest
    @AppStorage("vaultCollectionFilter") private var collectionFilter = CollectionFilter.all
    @AppStorage("vaultDisplayMode") private var displayMode = VaultDisplayMode.imagesOnly
    @State private var fileInfo: [URL: AssetFileInfo] = [:]
    @State private var fileInfoLoader = AssetFileInfoLoader()
    @State private var visibleItems: [VaultImage] = []
    @State private var refreshingFileInfo = false
    @State private var recentlySelectedID: UUID?
    @State private var previewedID: UUID?
    private var columns: [GridItem] {
        let scale = max(1, fontScale)
        if displayMode == .imagesOnly {
            return [GridItem(.adaptive(minimum: 150 * scale, maximum: 220 * scale), spacing: 3)]
        }
        return [GridItem(.adaptive(minimum: 215 * scale, maximum: 330 * scale), spacing: 16)]
    }

    private func updateVisibleItems() {
        let matching = matchingVaultImages(library.images, query: model.query, collectionFilter: collectionFilter,
                                          tagFilter: tagFilter, collectionMembers: library.collectionMembers)
        visibleItems = sortOrder.sorted(matching, date: { $0.createdAt }, size: { fileInfo[library.imageURL($0)]?.byteCount }, name: { $0.filename })
        let visibleSelection = model.selected.intersection(visibleItems.map(\.id))
        if visibleSelection != model.selected { model.selected = visibleSelection }
    }

    var body: some View {
        let items = visibleItems
        let visibleIDs = Set(items.map(\.id))
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                filterControls
                ScrollView(.horizontal) {
                    filterControls.fixedSize(horizontal: true, vertical: false)
                }.scrollIndicators(.hidden)
            }.frame(height: 28 * max(1, fontScale))
                .padding(.horizontal, 24).padding(.vertical, 10)
            if library.images.isEmpty {
                emptyState
            } else if items.isEmpty {
                ContentUnavailableView(collectionFilter == .unfiled ? L("没有匹配的未归类图片") : L("没有匹配的图片"),
                                       systemImage: "photo.on.rectangle", description: Text(collectionFilter == .unfiled
                                           ? L("加入收藏夹的图片仍保留在「全部」中，也可调整标签或搜索条件。")
                                           : L("试试其他标签或搜索条件。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { viewport in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: displayMode == .imagesOnly ? 3 : 16) {
                            ForEach(items) { item in
                                ImageCard(item: item, library: library, fileInfo: fileInfo[library.imageURL(item)],
                                          collections: library.collections(containing: .image(item.id)),
                                          selected: model.selected.contains(item.id),
                                          displayMode: displayMode,
                                          toggle: { modifiers in
                                              NSApp.currentEvent?.window?.makeFirstResponder(nil)
                                              model.selected = selection.select(item.id, in: items.map(\.id),
                                                                                modifiers: modifiers,
                                                                                selected: model.selected)
                                              recentlySelectedID = model.selected.contains(item.id) ? item.id : nil
                                          },
                                          edit: { model.edit(item) },
                                          preview: { previewImage(item.id) })
                                .contextMenu {
                                    Button(L("预览")) { previewImage(item.id) }
                                    Button(L("编辑标注")) { model.edit(item) }
                                    Button(L("宫格切图…")) { model.prepareImageExport([item], mode: .files, tool: .grid) }
                                        .disabled(model.isExporting)
                                    Button(L("浮窗贴图")) { model.pin(item) }
                                    Button(L("复制图片")) { model.copy(item) }
                                    Menu(L("加入收藏夹")) {
                                        AddToCollectionMenu(library: library, assets: [.image(item.id)]) { model.errorMessage = $0.localizedDescription }
                                    }
                                    Menu(L("颜色标签")) {
                                        AssetTagActions(selected: [item.tag]) { setTag($0, for: [item]) }
                                    }
                                    Button(L("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([library.imageURL(item)]) }
                                    Button(L("重命名")) {
                                        model.renameText = (item.filename as NSString).deletingPathExtension
                                        model.renameItem = item
                                    }
                                }
                                .onDrag {
                                    let ids = VaultSelection.draggedIDs(startingWith: item.id, visibleIDs: visibleIDs, selected: model.selected)
                                    return CollectionDrag.provider(assets: Set(ids.map(CollectionAsset.image)))
                                } preview: {
                                    CollectionDragPreview(title: item.filename,
                                                          count: VaultSelection.draggedIDs(startingWith: item.id, visibleIDs: visibleIDs, selected: model.selected).count,
                                                          symbol: "photo.on.rectangle")
                                }
                                .anchorPreference(key: VaultCardBounds.self, value: .bounds) { [item.id: $0] }
                            }
                        }
                        .padding(.horizontal, displayMode == .imagesOnly ? 12 : 24)
                        .padding(.bottom, displayMode == .imagesOnly ? 12 : 20)
                        .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                        .overlayPreferenceValue(VaultCardBounds.self) { anchors in
                            GeometryReader { geometry in
                                VaultMarqueeOverlay(frames: anchors.mapValues { geometry[$0] }, selected: model.selected,
                                                    onSelectionChange: { model.selected = $0 },
                                                    onBegin: { selection.anchor = nil })
                            }
                        }
                    }
                }
            }
            selectionBar
        }
        .background(SystemImagePreview(url: previewURL, urls: visibleItems.map(library.imageURL)))
        .confirmationDialog(L("将选中的 \(model.selected.count) 张图片移入系统废纸篓？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("移入废纸篓"), role: .destructive) { model.deleteSelected() }
        } message: {
            let count = model.selectedImageCollectionCount
            if count > 0 {
                Text(model.selected.count == 1
                     ? L("这张图片也在 \(count) 个收藏夹中，移入废纸篓后将从这些收藏夹中一并移除。")
                     : L("选中的图片涉及 \(count) 个收藏夹，移入废纸篓后将从这些收藏夹中一并移除。"))
            } else {
                Text(L("原文件将移入系统废纸篓。"))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipatoSelectAllVisibleAssets, object: model)) { _ in
            selection.anchor = nil
            model.selected = Set(visibleItems.map(\.id))
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipatoPreviewSelectedImage, object: model)) { _ in
            guard let id = VaultSelection.previewID(in: visibleItems.map(\.id), selected: model.selected,
                                                    preferredID: recentlySelectedID) else { return }
            previewedID = previewedID == id ? nil : id
        }
        .onAppear(perform: updateVisibleItems)
        .onChange(of: model.query) { _, _ in updateVisibleItems() }
        .onChange(of: tagFilter) { _, _ in updateVisibleItems() }
        .onChange(of: sortOrder) { _, _ in updateVisibleItems() }
        .onChange(of: collectionFilter) { _, _ in updateVisibleItems() }
        .onChange(of: library.collectionMembers) { _, _ in updateVisibleItems() }
        .onChange(of: library.images) { previous, current in
            let renames = renamedImageURLs(previous: previous, current: current, imageURL: library.imageURL)
            fileInfo = remappingAssetMetadata(fileInfo, renames: renames)
            updateVisibleItems()
        }
        .onChange(of: fileInfo) { _, _ in updateVisibleItems() }
        .onChange(of: visibleItems.map(\.id)) { _, ids in
            selection.anchor = nil
            if let previewedID, !ids.contains(previewedID) { self.previewedID = nil }
        }
        .onChange(of: model.selected) { _, ids in
            if let previewedID, !ids.contains(previewedID) { self.previewedID = nil }
        }
        .onChange(of: displayMode) { _, _ in previewedID = nil }
        .onDisappear { previewedID = nil; recentlySelectedID = nil }
        .task(id: library.images.map(library.imageURL)) {
            await loadFileInfo(refresh: false)
        }
    }

    private var previewURL: Binding<URL?> {
        Binding(get: {
            guard let previewedID, let item = library.images.first(where: { $0.id == previewedID }) else { return nil }
            return library.imageURL(item)
        }, set: { url in
            guard let url else { previewedID = nil; return }
            guard let item = visibleItems.first(where: { library.imageURL($0) == url }) else { return }
            previewImage(item.id)
        })
    }

    private func previewImage(_ id: UUID) {
        model.selected = [id]
        selection.anchor = id
        recentlySelectedID = id
        previewedID = id
    }

    private var filterControls: some View {
        let items = visibleItems
        let allVisibleSelected = !items.isEmpty && items.allSatisfy { model.selected.contains($0.id) }
        return HStack(spacing: 8) {
            VaultImageFilterControls(query: $model.query, collectionFilter: $collectionFilter,
                                     tagFilter: $tagFilter, sortOrder: $sortOrder)
            AssetScanMenu(model: model, assets: items.map { .image($0.id) },
                          selected: Set(model.selected.map(CollectionAsset.image)))
            Button {
                Task { await loadFileInfo(refresh: true) }
            } label: {
                Image(systemName: "arrow.clockwise").consoleFont(11)
                    .frame(width: 26 * max(1, fontScale), height: 28 * max(1, fontScale))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(refreshingFileInfo)
                .help(L("重新读取文件大小；连接外置磁盘后可重试")).accessibilityLabel(L("刷新文件大小"))
            Spacer()
            VaultDisplayModePicker(selection: $displayMode)
            Text(L("\(items.count) 张")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
            Button(allVisibleSelected ? L("取消") : L("全选")) {
                selection.anchor = nil
                let ids = Set(items.map(\.id))
                if allVisibleSelected { model.selected.subtract(ids) }
                else { model.selected.formUnion(ids) }
            }.buttonStyle(.plain).consoleFont(11).foregroundStyle(Palette.accent).fixedSize()
                .help(allVisibleSelected ? L("取消选择当前筛选结果") : L("选择当前筛选结果中的全部图片"))
                .accessibilityLabel(allVisibleSelected ? L("取消选择全部图片") : L("选择全部图片"))
        }
    }

    private func loadFileInfo(refresh: Bool) async {
        let urls = library.images.map(library.imageURL)
        refreshingFileInfo = true
        defer { refreshingFileInfo = false }
        if refresh { await fileInfoLoader.invalidate(urls) }
        do {
            let result = try await fileInfoLoader.load(urls)
            try Task.checkCancellation()
            // A manual refresh may finish after an import or deletion changes the list.
            guard urls == library.images.map(library.imageURL) else { return }
            fileInfo = result
        } catch is CancellationError {
            return
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func setTag(_ tag: AssetTag?, for items: [VaultImage]) {
        do { try library.setTag(tag, for: items) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "photo.on.rectangle").consoleFont(36, weight: .light)
                .foregroundStyle(.tertiary).padding(.bottom, 16)
            Text(L("暂无图片")).consoleFont(15, weight: .medium).padding(.bottom, 8)
            Text(L("截取屏幕或导入图片，选中多张后可拼图。"))
                .consoleFont(12).foregroundStyle(Palette.muted).padding(.bottom, 20)
            Button { model.capture(region: true) } label: { Label(L("截取区域"), systemImage: "viewfinder") }.buttonStyle(AccentButtonStyle())
            HStack(spacing: 8) {
                ShortcutLabel(shortcuts: model.shortcuts, action: .captureRegion)
                Text(L("截取区域快捷键"))
            }.consoleFont(10, design: .monospaced).foregroundStyle(Palette.muted).padding(.top, 16)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func prepareExport(_ mode: BatchExportMode) {
        model.prepareImageExport(visibleItems.filter { model.selected.contains($0.id) }, mode: mode)
    }

    private func prepareBatchRename() {
        model.prepareBatchRename(visibleItems.filter { model.selected.contains($0.id) }.map { .image($0.id) })
    }

    private var selectionBar: some View {
        let selectedItems = library.images.filter { model.selected.contains($0.id) }
        return ViewThatFits(in: .horizontal) {
            selectionControls(compact: false, selectedItems: selectedItems)
            selectionControls(compact: true, selectedItems: selectedItems)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(minHeight: 54).fixedSize(horizontal: false, vertical: true)
        .background(Palette.background)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func selectionControls(compact: Bool, selectedItems: [VaultImage]) -> some View {
        return HStack(spacing: 10) {
            Text(L("已选 \(model.selected.count) 张")).consoleFont(11).foregroundStyle(Palette.muted)
                .fixedSize().help(L("单击选择 · ⌘ 点击切换选择 · ⇧ 点击选范围 · ⌘A 全选 · 空白处拖框选中 / 反选"))
            Spacer()
            if compact {
                Menu {
                    Menu(L("加入收藏夹")) {
                        AddToCollectionMenu(library: library, assets: Set(selectedItems.map { .image($0.id) })) { model.errorMessage = $0.localizedDescription }
                    }
                    Menu(L("颜色标签")) {
                        AssetTagActions(selected: Set(selectedItems.map(\.tag))) { setTag($0, for: selectedItems) }
                    }.disabled(selectedItems.isEmpty)
                    if selectedItems.count > 1 {
                        Button(L("批量命名…"), action: prepareBatchRename).disabled(model.isExporting)
                    }
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label(L("移入废纸篓"), systemImage: "trash") }
                        .disabled(model.selected.isEmpty)
                } label: {
                    Label(L("更多"), systemImage: "ellipsis").consoleFont(12, weight: .medium)
                        .menuLabel()
                }.menuStyle(.borderlessButton).fixedSize().disabled(model.selected.isEmpty)
            } else {
                Menu {
                    AddToCollectionMenu(library: library, assets: Set(selectedItems.map { .image($0.id) })) { model.errorMessage = $0.localizedDescription }
                } label: {
                    Image(systemName: "folder.badge.plus").consoleFont(12)
                        .menuLabel(minimumWidth: 30, padding: 4)
                }.menuStyle(.borderlessButton).fixedSize().disabled(selectedItems.isEmpty)
                    .help(L("加入收藏夹")).accessibilityLabel(L("加入收藏夹"))
                Menu {
                    AssetTagActions(selected: Set(selectedItems.map(\.tag))) { setTag($0, for: selectedItems) }
                } label: {
                    Label(L("标签"), systemImage: "tag").consoleFont(12, weight: .medium)
                        .menuLabel()
                }.menuStyle(.borderlessButton).fixedSize().disabled(selectedItems.isEmpty)
                if selectedItems.count > 1 {
                    Button(action: prepareBatchRename) { Label(L("批量命名"), systemImage: "pencil") }
                        .buttonStyle(QuietButtonStyle()).disabled(model.isExporting).fixedSize()
                }
                Button { confirmDelete = true } label: { Label(L("移入废纸篓"), systemImage: "trash") }
                    .buttonStyle(QuietButtonStyle()).disabled(model.selected.isEmpty).fixedSize()
            }
            Menu {
                Button(L("图片 / PDF…")) { prepareExport(.files) }
                Button(L("ZIP 压缩包…")) { prepareExport(.zip) }
                Button("MP4 / GIF…") { prepareExport(.video) }
                Divider()
                Button(L("压缩体积…")) { model.prepareImageExport(selectedItems, mode: .files, tool: .compress) }
                Button(L("调整尺寸…")) { model.prepareImageExport(selectedItems, mode: .files, tool: .resize) }
                Button(L("转换格式…")) { model.prepareImageExport(selectedItems, mode: .files, tool: .convert) }
            } label: {
                Label(L("导出"), systemImage: "square.and.arrow.up").consoleFont(12, weight: .medium)
                    .menuLabel()
            }.menuStyle(.borderlessButton).fixedSize()
                .disabled(!visibleItems.contains { model.selected.contains($0.id) } || model.isExporting)
            Button { model.composeLongScreenshot() } label: { Label(L("长图拼接"), systemImage: "rectangle.portrait") }
                .buttonStyle(QuietButtonStyle())
                .disabled(!model.hasCollageWorkspace && (model.selected.isEmpty || model.preparingCollectionFrames || model.fixedCaptureRegion != nil || model.capturing)).fixedSize()
            Button { model.compose() } label: { Label(compact ? L("拼图") : L("Grid / 自由拼图"), systemImage: "square.grid.2x2") }
                .buttonStyle(AccentButtonStyle())
                .disabled(!model.hasCollageWorkspace && (model.selected.isEmpty || model.preparingCollectionFrames || model.fixedCaptureRegion != nil || model.capturing)).fixedSize().help(L("Grid / 自由拼图"))
        }
    }
}

struct VaultCardBounds: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ImageCard: View {
    let item: VaultImage
    let library: LibraryStore
    let fileInfo: AssetFileInfo?
    let collections: [AssetCollection]
    let selected: Bool
    var displayMode: VaultDisplayMode = .standard
    let toggle: (NSEvent.ModifierFlags) -> Void
    let edit: (() -> Void)?
    var preview: (() -> Void)? = nil
    @State private var thumbnail: NSImage?
    @State private var thumbnailError: String?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sourceTitle: String {
        switch item.source {
        case "截图": return L("截图")
        case "长截图": return L("长截图")
        case "标注": return L("标注")
        case "拼图": return L("拼图")
        case "导入": return L("导入")
        case "关键帧": return L("关键帧")
        default: return item.source
        }
    }

    private var helpText: String {
        if let thumbnailError { return thumbnailError }
        let membership = collections.isEmpty ? "" : L("已加入：\(collections.map(\.name).joined(separator: "、"))\n")
        guard preview != nil else { return membership + L("选择图片") }
        let actions = L("拖到侧栏收藏夹归类 · 单击单选 · ⌘ 点击多选 · ⇧ 点击选范围 · ⌘A 全选 · 双击预览")
        let previewShortcut = displayMode == .imagesOnly ? "\n" + L("空格预览 · Esc 关闭") : ""
        return membership + actions + previewShortcut
    }

    private func selectImage() {
        // Select immediately; the second click belongs to the preview action.
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount > 1 { return }
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        toggle(modifiers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailArea
                .clipped()
                .overlay(alignment: .topLeading) {
                    CollectionMembershipBadge(collections: collections)
                        .padding(.leading, 8).padding(.trailing, 38).padding(.top, 8)
                        .opacity(displayMode == .standard || isHovered ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                        .allowsHitTesting(false)
                        .accessibilityHidden(displayMode == .imagesOnly && !isHovered)
                }
            if displayMode == .standard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        if let tag = item.tag {
                            Circle().fill(tag.color).frame(width: 8, height: 8)
                                .help(L("\(tag.title)标签")).accessibilityLabel(L("\(tag.title)标签"))
                        }
                        Text((item.filename as NSString).deletingPathExtension).consoleFont(11, weight: .medium).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text("\(item.width) × \(item.height)").consoleFont(9, design: .monospaced)
                            .fixedSize()
                        Text(sourceTitle).consoleFont(9).lineLimit(1)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 3))
                            .help(sourceTitle)
                        Spacer()
                        Text(fileInfo?.label ?? L("读取大小…")).consoleFont(10)
                            .fixedSize()
                            .help(fileInfo?.help ?? L("正在读取文件大小"))
                    }.foregroundStyle(Palette.muted)
                }.padding(11)
            }
        }
        .background(displayMode == .standard ? Palette.card : .clear)
        .clipShape(RoundedRectangle(cornerRadius: displayMode == .standard ? 8 : 0))
        .overlay {
            SurfaceBorder(color: selected ? Palette.accent : Palette.line,
                          cornerRadius: displayMode == .standard ? 8 : 0,
                          lineWidth: selected ? 1.5 : (displayMode == .imagesOnly ? 1 : 0.5))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: selectImage)
        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in
            if let preview { preview() }
        })
        .task(id: library.imageURL(item)) {
            do {
                thumbnailError = nil
                thumbnail = try await library.thumbnail(item)
            } catch is CancellationError {
                return
            } catch {
                thumbnailError = error.localizedDescription
            }
        }
        .onDisappear { thumbnail = nil; isHovered = false }
        .accessibilityLabel((item.filename as NSString).deletingPathExtension)
        .accessibilityActions {
            if let edit { Button(L("编辑标注"), action: edit) }
            if let preview { Button(L("预览"), action: preview) }
        }
        .help(helpText)
    }

    @ViewBuilder
    private var thumbnailArea: some View {
        if displayMode == .imagesOnly {
            thumbnailContent.aspectRatio(1, contentMode: .fit)
        } else {
            thumbnailContent.frame(height: 155)
        }
    }

    private var thumbnailContent: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(Palette.canvas)
            if let thumbnail {
                Image(nsImage: thumbnail).resizable()
                    .scaledToFit()
                    .background {
                        if preview != nil {
                            ImagePreviewSource(url: library.imageURL(item), image: thumbnail)
                        }
                    }
                    .padding(displayMode == .standard ? 10 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: thumbnailError == nil ? "photo" : "photo.badge.exclamationmark")
                    .consoleFont(24, weight: .light).foregroundStyle(.tertiary)
            }
            Image(systemName: "checkmark.circle.fill")
                .consoleFont(18).foregroundStyle(Palette.accent)
                .background(Palette.card, in: Circle()).padding(9).opacity(selected ? 1 : 0)
        }
    }
}
