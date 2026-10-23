import AppKit
import SwiftUI

struct VaultImagePickerView: View {
    @ObservedObject var library: LibraryStore
    @Binding var selected: Set<UUID>
    let allowsMultipleSelection: Bool
    var minimumSelectionCount = 1
    let onCancel: () -> Void
    let onChoose: ([VaultImage]) -> Void
    @Environment(\.consoleFontScale) private var fontScale
    @State private var query = ""
    @State private var tagFilter = AssetTagFilter.all
    @State private var collectionFilter = CollectionFilter.all
    @State private var sortOrder = AssetSortOrder.newest
    @AppStorage("vaultDisplayMode") private var displayMode = VaultDisplayMode.imagesOnly
    @State private var visibleItems: [VaultImage] = []
    @State private var fileInfo: [URL: AssetFileInfo] = [:]
    @State private var fileInfoLoader = AssetFileInfoLoader()
    @State private var fileInfoTask: Task<Void, Never>?
    @State private var refreshingFileInfo = false
    @State private var fileInfoError: String?
    @State private var anchor: UUID?
    @FocusState private var gridFocused: Bool

    private var columns: [GridItem] {
        let scale = max(1, fontScale)
        if displayMode == .imagesOnly {
            return [GridItem(.adaptive(minimum: 150 * scale, maximum: 220 * scale), spacing: 3)]
        }
        return [GridItem(.adaptive(minimum: 215 * scale, maximum: 330 * scale), spacing: 16)]
    }

    var body: some View {
        let visibleIDs = visibleItems.map(\.id)
        let selectedImages = library.images.filter { selected.contains($0.id) }
        let allVisibleSelected = !visibleIDs.isEmpty && Set(visibleIDs).isSubset(of: selected)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("选择保管箱图片")).consoleFont(16, weight: .semibold)
                Spacer(minLength: 8)
                if allowsMultipleSelection {
                    Button(allVisibleSelected ? L("取消全选") : L("全选")) {
                        anchor = nil
                        if allVisibleSelected { selected.subtract(visibleIDs) }
                        else { selected.formUnion(visibleIDs) }
                        gridFocused = true
                    }
                    .buttonStyle(QuietButtonStyle()).disabled(visibleItems.isEmpty)
                }
            }
            .padding(20)
            ViewThatFits(in: .horizontal) {
                filterControls
                ScrollView(.horizontal) {
                    filterControls.fixedSize(horizontal: true, vertical: false)
                }.scrollIndicators(.hidden)
            }
            .frame(height: 28 * max(1, fontScale))
            .padding(.horizontal, 20).padding(.bottom, 14)
            if let fileInfoError {
                Label(fileInfoError, systemImage: "exclamationmark.triangle")
                    .consoleFont(11).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider().overlay(Palette.line)
            if visibleItems.isEmpty {
                ContentUnavailableView(collectionFilter == .unfiled ? L("没有匹配的未归类图片") : L("没有匹配的图片"),
                                       systemImage: "photo.on.rectangle", description: Text(collectionFilter == .unfiled
                                           ? L("加入收藏夹的图片仍保留在「全部」中，也可调整标签或搜索条件。")
                                           : L("试试其他标签或搜索条件。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: displayMode == .imagesOnly ? 3 : 16) {
                        ForEach(visibleItems) { item in
                            ImageCard(item: item, library: library, fileInfo: fileInfo[library.imageURL(item)],
                                      collections: library.collections(containing: .image(item.id)),
                                      selected: selected.contains(item.id), displayMode: displayMode,
                                      toggle: { modifiers in
                                          if allowsMultipleSelection {
                                              selected = VaultSelection.select(item.id, in: visibleIDs,
                                                                               modifiers: modifiers,
                                                                               anchor: &anchor, selected: selected)
                                          } else {
                                              selected = [item.id]
                                              anchor = item.id
                                          }
                                          gridFocused = true
                                      }, edit: nil)
                        }
                    }
                    .padding(.horizontal, displayMode == .imagesOnly ? 12 : 24)
                    .padding(.bottom, displayMode == .imagesOnly ? 12 : 20)
                }
                .focusable(allowsMultipleSelection)
                .focused($gridFocused)
                .onCommand(#selector(NSText.selectAll(_:)), perform: allowsMultipleSelection ? {
                    selected.formUnion(visibleIDs)
                    anchor = nil
                } : nil)
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("已选 \(selectedImages.count) 张"))
                    if minimumSelectionCount > 1 && selectedImages.count < minimumSelectionCount {
                        Label(L("请至少选择 \(minimumSelectionCount) 张图片。"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.warning).fontWeight(.semibold)
                            .accessibilityIdentifier("vault-image-picker-selection-warning")
                    }
                }
                .consoleFont(11).foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Button(L("取消"), action: onCancel)
                    .buttonStyle(QuietButtonStyle())
                Button(L("使用所选图片")) {
                    onChoose(sortedImages(library.images.filter { selected.contains($0.id) }))
                }
                .buttonStyle(AccentButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(selectedImages.count < minimumSelectionCount || (!allowsMultipleSelection && selectedImages.count != 1))
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("vault-image-picker")
        .foregroundStyle(Palette.foreground).background(Palette.background)
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
        .onAppear {
            reconcileSelection(with: library.images.map(\.id))
            updateVisibleItems()
            loadFileInfo(refresh: false)
        }
        .onChange(of: query) { _, _ in updateVisibleItems() }
        .onChange(of: tagFilter) { _, _ in updateVisibleItems() }
        .onChange(of: sortOrder) { _, _ in updateVisibleItems() }
        .onChange(of: collectionFilter) { _, _ in updateVisibleItems() }
        .onChange(of: library.collectionMembers) { _, _ in updateVisibleItems() }
        .onChange(of: library.images) { previous, current in
            let renames = renamedImageURLs(previous: previous, current: current, imageURL: library.imageURL)
            fileInfo = remappingAssetMetadata(fileInfo, renames: renames)
            reconcileSelection(with: current.map(\.id))
            updateVisibleItems()
        }
        .onChange(of: library.images.map(library.imageURL)) { _, _ in loadFileInfo(refresh: false) }
        .onChange(of: fileInfo) { _, _ in updateVisibleItems() }
        .onDisappear {
            fileInfoTask?.cancel()
            fileInfoTask = nil
            refreshingFileInfo = false
        }
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            VaultImageFilterControls(query: $query, collectionFilter: $collectionFilter,
                                     tagFilter: $tagFilter, sortOrder: $sortOrder)
            Button { loadFileInfo(refresh: true) } label: {
                Image(systemName: "arrow.clockwise").consoleFont(11)
                    .frame(width: 26 * max(1, fontScale), height: 28 * max(1, fontScale))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(refreshingFileInfo)
            .help(L("重新读取文件大小；连接外置磁盘后可重试")).accessibilityLabel(L("刷新文件大小"))
            Spacer(minLength: 0)
            VaultDisplayModePicker(selection: $displayMode)
            Text(L("\(visibleItems.count) 张")).consoleFont(11).foregroundStyle(Palette.muted).fixedSize()
        }
    }

    private func sortedImages(_ images: [VaultImage]) -> [VaultImage] {
        sortOrder.sorted(images, date: { $0.createdAt }, size: { fileInfo[library.imageURL($0)]?.byteCount }, name: { $0.filename })
    }

    private func updateVisibleItems() {
        visibleItems = sortedImages(matchingVaultImages(library.images, query: query, collectionFilter: collectionFilter,
                                                        tagFilter: tagFilter, collectionMembers: library.collectionMembers))
        anchor = nil
    }

    private func loadFileInfo(refresh: Bool) {
        fileInfoTask?.cancel()
        let urls = library.images.map(library.imageURL)
        refreshingFileInfo = true
        fileInfoError = nil
        fileInfoTask = Task {
            if refresh { await fileInfoLoader.invalidate(urls) }
            do {
                let result = try await fileInfoLoader.load(urls)
                try Task.checkCancellation()
                guard urls == library.images.map(library.imageURL) else { return }
                fileInfo = result
                refreshingFileInfo = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                fileInfoError = error.localizedDescription
                refreshingFileInfo = false
            }
        }
    }

    private func reconcileSelection(with ids: [UUID]) {
        let validIDs = Set(ids)
        let selection = selected.intersection(validIDs)
        if selection != selected { selected = selection }
        if let anchor, !validIDs.contains(anchor) { self.anchor = nil }
    }
}
