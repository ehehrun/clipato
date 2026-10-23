import AppKit
import SwiftUI

enum AssetTag: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, blue, purple, gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .red: return L("红色")
        case .orange: return L("橙色")
        case .yellow: return L("黄色")
        case .green: return L("绿色")
        case .blue: return L("蓝色")
        case .purple: return L("紫色")
        case .gray: return L("灰色")
        }
    }

    var color: Color {
        switch self {
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .blue: return Color(nsColor: .systemBlue)
        case .purple: return Color(nsColor: .systemPurple)
        case .gray: return Color(nsColor: .systemGray)
        }
    }

    var swatch: NSImage { Self.swatches[self]! }

    private static let swatches: [AssetTag: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map { tag in
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(tag.color).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = false
        return (tag, image)
    })
}

enum AssetTagFilter: Hashable, CaseIterable, Identifiable {
    case all, untagged, tag(AssetTag)

    static var allCases: [AssetTagFilter] { [.all, .untagged] + AssetTag.allCases.map(Self.tag) }
    var id: Self { self }

    var title: String {
        switch self {
        case .all: return L("全部标签")
        case .untagged: return L("无标签")
        case .tag(let tag): return tag.title
        }
    }

    func includes(_ tag: AssetTag?) -> Bool {
        switch self {
        case .all: return true
        case .untagged: return tag == nil
        case .tag(let selected): return tag == selected
        }
    }
}

struct AssetTagLabel: View {
    let tag: AssetTag
    @Environment(\.consoleFontScale) private var fontScale

    var body: some View {
        Label {
            Text(tag.title)
        } icon: {
            Image(nsImage: tag.swatch).renderingMode(.original).resizable()
                .frame(width: 12 * fontScale, height: 12 * fontScale)
        }
    }
}

struct AssetTagActions: View {
    let selected: Set<AssetTag?>
    let onSelect: (AssetTag?) -> Void

    var body: some View {
        ForEach(AssetTag.allCases) { tag in
            Toggle(isOn: Binding(get: { selected == [tag] }, set: { isOn in
                if isOn { onSelect(tag) }
            })) {
                AssetTagLabel(tag: tag)
            }
        }
        Divider()
        Toggle(L("清除标签"), isOn: Binding(get: { selected == [nil] }, set: { isOn in
            if isOn { onSelect(nil) }
        })).disabled(selected == [nil])
    }
}

struct AssetTagFilterPicker: View {
    @Binding var selection: AssetTagFilter

    var body: some View {
        Menu {
            Picker(L("标签"), selection: $selection) {
                ForEach(AssetTagFilter.allCases) { filter in
                    if case .tag(let tag) = filter {
                        AssetTagLabel(tag: tag).tag(filter)
                    } else {
                        Text(filter.title).tag(filter)
                    }
                }
            }.pickerStyle(.inline)
        } label: {
            Group {
                if case .tag(let tag) = selection {
                    AssetTagLabel(tag: tag)
                } else {
                    Label(selection == .all ? L("标签") : L("无标签"), systemImage: "tag")
                }
            }.consoleFont(11).menuLabel(minimumWidth: 0, padding: 4)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("按颜色标签筛选：\(selection.title)"))
        .accessibilityLabel(L("标签筛选"))
        .accessibilityValue(selection.title)
    }
}
