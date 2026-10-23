import SwiftUI

struct AssetSortPicker: View {
    @Binding var selection: AssetSortOrder

    private var ascending: Binding<Bool> {
        Binding(get: { selection.isAscending }, set: { value in
            if selection.isName { selection = value ? .nameAscending : .nameDescending }
            else if selection.isSize { selection = value ? .sizeAscending : .sizeDescending }
            else { selection = value ? .oldest : .newest }
        })
    }

    private var shortTitle: String {
        if selection.isName { return L("名称") }
        return selection.isSize ? L("大小") : L("时间")
    }

    private var ascendingTitle: String {
        if selection.isName { return L("正序 · A–Z") }
        return selection.isSize ? L("正序 · 小到大") : L("正序 · 旧到新")
    }

    private var descendingTitle: String {
        if selection.isName { return L("倒序 · Z–A") }
        return selection.isSize ? L("倒序 · 大到小") : L("倒序 · 新到旧")
    }

    var body: some View {
        Menu {
            Picker(L("排序依据"), selection: $selection) {
                Label(L("按时间"), systemImage: "clock")
                    .tag(selection.isAscending ? AssetSortOrder.oldest : .newest)
                Label(L("按大小"), systemImage: "internaldrive")
                    .tag(selection.isAscending ? AssetSortOrder.sizeAscending : .sizeDescending)
                Label(L("按名称"), systemImage: "textformat.abc")
                    .tag(selection.isAscending ? AssetSortOrder.nameAscending : .nameDescending)
            }.pickerStyle(.inline)
            Divider()
            Picker(L("顺序"), selection: ascending) {
                Text(ascendingTitle).tag(true)
                Text(descendingTitle).tag(false)
            }.pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(shortTitle)
                Image(systemName: selection.isAscending ? "arrow.up" : "arrow.down")
            }.consoleFont(11).menuLabel(minimumWidth: 0, padding: 4)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(selection.title)
        .accessibilityLabel(L("排序"))
        .accessibilityValue(selection.title)
    }
}
