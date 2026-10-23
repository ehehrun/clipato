import SwiftUI

func matchingVaultImages(_ images: [VaultImage], query: String, collectionFilter: CollectionFilter,
                         tagFilter: AssetTagFilter, collectionMembers: [UUID: Set<CollectionAsset>]) -> [VaultImage] {
    let collectedAssets = collectionFilter == .unfiled
        ? collectionMembers.values.reduce(into: Set<CollectionAsset>()) { $0.formUnion($1) }
        : []
    return images.filter {
        collectionFilter.includes(.image($0.id), collectedAssets: collectedAssets) &&
            tagFilter.includes($0.tag) && (query.isEmpty ||
            $0.filename.localizedCaseInsensitiveContains(query) || $0.source.localizedCaseInsensitiveContains(query))
    }
}

struct VaultImageFilterControls: View {
    @Binding var query: String
    @Binding var collectionFilter: CollectionFilter
    @Binding var tagFilter: AssetTagFilter
    @Binding var sortOrder: AssetSortOrder
    @Environment(\.consoleFontScale) private var fontScale

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField(L("搜索"), text: $query).textFieldStyle(.plain).consoleFont(12)
                    .environment(\.isFocusEffectEnabled, true)
                    .help(L("搜索名称或来源")).accessibilityLabel(L("搜索名称或来源"))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 8).frame(height: 28 * max(1, fontScale))
            .frame(minWidth: 100 * max(1, fontScale), maxWidth: 180 * max(1, fontScale))
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay { SurfaceBorder(cornerRadius: 6) }
            CollectionFilterPicker(selection: $collectionFilter)
            AssetTagFilterPicker(selection: $tagFilter)
            AssetSortPicker(selection: $sortOrder)
        }
    }
}

struct VaultDisplayModePicker: View {
    @Binding var selection: VaultDisplayMode

    var body: some View {
        Menu {
            Picker(L("展示模式"), selection: $selection) {
                Label(L("概览"), systemImage: VaultDisplayMode.imagesOnly.symbol).tag(VaultDisplayMode.imagesOnly)
                Label(L("卡片"), systemImage: VaultDisplayMode.standard.symbol).tag(VaultDisplayMode.standard)
            }.pickerStyle(.inline)
        } label: {
            Label(selection.title, systemImage: selection.symbol)
                .consoleFont(11).menuLabel(minimumWidth: 0, padding: 4)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("展示模式：\(selection.title) · 概览仅展示图片，悬停查看收藏夹"))
        .accessibilityLabel(L("展示模式")).accessibilityValue(selection.title)
    }
}
