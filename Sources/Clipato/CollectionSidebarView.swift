import SwiftUI
import AppKit

struct CollectionSidebarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale
    @State private var editMode: EditMode?
    @State private var name = ""
    @State private var deleting: AssetCollection?
    @State private var folderTarget: UUID?
    @State private var insertionTarget: UUID?
    @State private var endTarget = false

    private enum EditMode {
        case create
        case rename(UUID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(L("收藏夹")).consoleFont(10, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { beginCreate() } label: {
                    Image(systemName: "plus").consoleFont(10, weight: .semibold)
                        .frame(width: 24 * fontScale, height: 24 * fontScale).contentShape(Rectangle())
                }
                .buttonStyle(SidebarItemStyle(isSelected: false))
                .help(L("新建收藏夹")).accessibilityLabel(L("新建收藏夹"))
            }
            .foregroundStyle(Palette.muted).padding(.leading, 10)
            .padding(.bottom, 2)
            ForEach(orderedCollections) { collection in
                insertionLine(before: collection)
                row(collection)
            }
            Rectangle().fill(endTarget ? Palette.accent : .clear)
                .frame(height: 6).contentShape(Rectangle())
                .onDrop(of: [CollectionDrag.folderType.identifier], isTargeted: $endTarget) { providers in
                    moveDroppedFolder(providers)
                }

            if library.collections.isEmpty {
                Text(L("按项目或主题整理内容"))
                    .consoleFont(10).foregroundStyle(Palette.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .focusEffectDisabled()
        .alert(editTitle, isPresented: Binding(get: { editMode != nil }, set: { if !$0 { editMode = nil } })) {
            TextField(L("收藏夹名称"), text: $name).environment(\.isFocusEffectEnabled, true)
            Button(L("取消"), role: .cancel) { editMode = nil }
            Button(L("保存")) { saveName() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(L("删除收藏夹？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("取消"), role: .cancel) { deleting = nil }
            Button(L("删除收藏夹"), role: .destructive) { deleteCollection() }
        } message: {
            Text(L("“\(deleting?.name ?? "")”将被删除，图片和录屏文件仍保留在保管箱。"))
        }
    }

    private func row(_ collection: AssetCollection) -> some View {
        let isSelected = model.section == .collections && model.selectedCollectionID == collection.id
        let isTarget = folderTarget == collection.id
        return Button { model.selectCollection(collection.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: isTarget ? "folder.badge.plus" : collection.color == nil ? "folder" : "folder.fill")
                    .consoleFont(14, weight: .medium)
                    .frame(width: 20 * fontScale, height: 20 * fontScale)
                    .foregroundStyle(collection.color?.color ?? (isSelected ? Palette.onAccent : isTarget ? Palette.accent : Palette.muted))
                    .background {
                        if isSelected && collection.color != nil {
                            RoundedRectangle(cornerRadius: 4).fill(Palette.onAccent)
                        }
                    }
                Text(collection.name).consoleFont(12, weight: isSelected ? .semibold : .medium)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                let count = library.collectionMembers[collection.id, default: []].count
                if count > 0 { SidebarCount(count: count, isSelected: isSelected) }
            }
            .padding(.leading, 10).padding(.trailing, 6)
            .frame(height: 36 * max(1, fontScale))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(isSelected: isSelected, isDropTarget: isTarget))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(collection.color?.title ?? L("默认颜色"))
        .contentShape(Rectangle())
        .help(L("\(collection.name) · 将图片或录屏拖到此处加入收藏夹"))
        .contextMenu { contextMenu(collection) }
        .onDrag { CollectionDrag.provider(collection: collection) } preview: {
            Label(collection.name, systemImage: "folder").consoleFont(12)
                .padding(10).background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
        }
        .onDrop(of: [CollectionDrag.assetType.identifier],
                isTargeted: targetBinding(for: collection.id, insertion: false)) { providers in
            dropIntoFolder(providers, collection: collection)
        }
    }

    private func insertionLine(before collection: AssetCollection) -> some View {
        Rectangle().fill(insertionTarget == collection.id ? Palette.accent : .clear)
            .frame(height: 4).contentShape(Rectangle())
            .onDrop(of: [CollectionDrag.folderType.identifier],
                    isTargeted: targetBinding(for: collection.id, insertion: true)) { providers in
                moveDroppedFolder(providers, before: collection.id)
            }
    }

    @ViewBuilder private func contextMenu(_ collection: AssetCollection) -> some View {
        Button(L("重命名")) { name = collection.name; editMode = .rename(collection.id) }
        Menu(L("文件夹颜色")) {
            Picker(L("文件夹颜色"), selection: Binding(get: { collection.color }, set: { color in
                do { try library.setCollectionColor(collection.id, color: color) }
                catch { model.errorMessage = error.localizedDescription }
            })) {
                Text(L("默认颜色")).tag(AssetTag?.none)
                ForEach(AssetTag.allCases) { color in
                    AssetTagLabel(tag: color).tag(Optional(color))
                }
            }.pickerStyle(.inline)
        }
        Divider()
        let siblings = orderedCollections
        if let index = siblings.firstIndex(where: { $0.id == collection.id }) {
            Button(L("上移")) { move(collection.id, before: siblings[index - 1].id) }
                .disabled(index == 0)
            Button(L("下移")) {
                move(collection.id, before: index + 2 < siblings.count ? siblings[index + 2].id : nil)
            }
            .disabled(index == siblings.count - 1)
        }
        Divider()
        Button(L("删除收藏夹…"), role: .destructive) { deleting = collection }
    }

    private var orderedCollections: [AssetCollection] {
        library.collections.sorted { $0.position < $1.position }
    }

    private var editTitle: String {
        if case .rename? = editMode { return L("重命名收藏夹") }
        return L("新建收藏夹")
    }

    private func beginCreate() {
        name = ""
        editMode = .create
    }

    private func saveName() {
        guard let mode = editMode else { return }
        do {
            switch mode {
            case .create:
                let collection = try library.createCollection(name: name)
                model.selectCollection(collection.id)
            case let .rename(id): try library.renameCollection(id, name: name)
            }
        } catch { model.errorMessage = error.localizedDescription }
        editMode = nil
    }

    private func deleteCollection() {
        guard let collection = deleting else { return }
        do {
            try library.deleteCollection(collection.id)
            if let selectedID = model.selectedCollectionID, !library.collections.contains(where: { $0.id == selectedID }) {
                model.selectedCollectionID = nil
                model.section = .collections
            }
        } catch { model.errorMessage = error.localizedDescription }
        deleting = nil
    }

    private func targetBinding(for id: UUID, insertion: Bool) -> Binding<Bool> {
        Binding(get: { (insertion ? insertionTarget : folderTarget) == id }, set: { value in
            if insertion {
                if value { insertionTarget = id } else if insertionTarget == id { insertionTarget = nil }
            } else {
                if value { folderTarget = id } else if folderTarget == id { folderTarget = nil }
            }
        })
    }

    private func dropIntoFolder(_ providers: [NSItemProvider], collection: AssetCollection) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(CollectionDrag.assetType.identifier) }) {
            CollectionDrag.loadAssets(from: provider) { result in
                do {
                    let assets = try result.get()
                    let added = assets.subtracting(library.collectionMembers[collection.id, default: []]).count
                    try library.addToCollection(collection.id, assets: assets)
                    model.notice = added == 0 ? L("这些内容已在「\(collection.name)」中") : L("已将 \(added) 项加入「\(collection.name)」")
                } catch { model.errorMessage = error.localizedDescription }
                folderTarget = nil
            }
            return true
        }
        return false
    }

    private func moveDroppedFolder(_ providers: [NSItemProvider], before: UUID? = nil) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(CollectionDrag.folderType.identifier) }) else { return false }
        CollectionDrag.loadCollection(from: provider) { result in
            do {
                let id = try result.get()
                if id != before { move(id, before: before) }
            } catch { model.errorMessage = error.localizedDescription }
            insertionTarget = nil
            folderTarget = nil
            endTarget = false
        }
        return true
    }

    private func move(_ id: UUID, before: UUID? = nil) {
        do {
            try library.moveCollection(id, toParent: nil, before: before)
        } catch { model.errorMessage = error.localizedDescription }
    }
}
