import SwiftUI

enum CollectionFilter: String, CaseIterable {
    case all, unfiled

    var title: String {
        switch self {
        case .all: return L("全部")
        case .unfiled: return L("未归类")
        }
    }

    func includes(_ asset: CollectionAsset, collectedAssets: Set<CollectionAsset>) -> Bool {
        self == .all || !collectedAssets.contains(asset)
    }
}

struct CollectionFilterPicker: View {
    @Binding var selection: CollectionFilter
    @Environment(\.consoleFontScale) private var fontScale

    var body: some View {
        Picker(L("收藏夹归类"), selection: $selection) {
            ForEach(CollectionFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .consoleFont(11)
        .frame(minWidth: 126 * max(1, fontScale))
        .fixedSize(horizontal: true, vertical: false)
        .focusEffectDisabled()
        .help(L("未归类仅显示尚未加入任何收藏夹的内容"))
        .accessibilityLabel(L("收藏夹归类"))
        .accessibilityValue(selection.title)
    }
}

struct CollectionMembershipBadge: View {
    let collections: [AssetCollection]
    @Environment(\.consoleFontScale) private var fontScale

    var body: some View {
        if let first = collections.first {
            let names = collections.map(\.name).joined(separator: "、")
            HStack(spacing: 4) {
                Image(systemName: first.color == nil ? "folder" : "folder.fill")
                    .foregroundStyle(first.color?.color ?? Palette.muted)
                    .accessibilityHidden(true)
                Text(first.name).lineLimit(1).truncationMode(.tail)
                if collections.count > 1 {
                    Text("+\(collections.count - 1)").fixedSize()
                }
            }
            .consoleFont(10)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: 160 * fontScale, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 4))
            .overlay { SurfaceBorder(cornerRadius: 4) }
            .help(L("已加入收藏夹：\(names)"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("已加入收藏夹：\(names)"))
        }
    }
}
