import AppKit
import SwiftUI

struct KeyframePickerView: View {
    let session: SavedSession
    let library: LibraryStore
    let onCompose: ([Int], Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var anchor: Int?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("选择关键帧")).consoleFont(16, weight: .semibold)
                    Text(L("按时间顺序参与拼图，原录制保持完整。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(selected.count == session.manifest.frames.count ? L("取消全选") : L("全选")) {
                    anchor = nil
                    selected = selected.count == session.manifest.frames.count ? [] : Set(session.manifest.frames.indices)
                }.buttonStyle(QuietButtonStyle()).disabled(session.manifest.frames.isEmpty)
            }.padding(20)
            Divider().overlay(Palette.line)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(session.manifest.frames.indices, id: \.self) { index in
                        let frame = session.manifest.frames[index]
                        KeyframePickerCard(library: library, session: session,
                                           index: index, time: frame.time, selected: selected.contains(index)) {
                            selected = VaultSelection.select(index, in: Array(session.manifest.frames.indices),
                                                             modifiers: NSApp.currentEvent?.modifierFlags ?? [],
                                                             anchor: &anchor, selected: selected)
                        }
                    }
                }.padding(20)
            }
            Divider().overlay(Palette.line)
            HStack(spacing: 12) {
                Text(L("已选 \(selected.count) / \(session.manifest.frames.count) 帧"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                Spacer()
                Button(L("取消")) { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(L("长图拼接")) { onCompose(selected.sorted(), true) }
                    .buttonStyle(QuietButtonStyle()).disabled(selected.isEmpty)
                Button(L("拼图 · \(selected.count) 张")) { onCompose(selected.sorted(), false) }
                    .buttonStyle(AccentButtonStyle()).disabled(selected.isEmpty)
            }.padding(20)
        }
        .frame(minWidth: 660, idealWidth: 760, minHeight: 440, idealHeight: 560)
        .foregroundStyle(Palette.foreground).background(Palette.background)
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
        .onExitCommand { dismiss() }
    }
}

private struct KeyframePickerCard: View {
    let library: LibraryStore
    let session: SavedSession
    let index: Int
    let time: TimeInterval
    let selected: Bool
    let select: () -> Void
    @State private var thumbnail: NSImage?
    @State private var thumbnailError: String?

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(Palette.canvas)
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit().padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: thumbnailError == nil ? "photo" : "photo.badge.exclamationmark")
                            .foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                            .background(Palette.card, in: Circle()).padding(8)
                    }
                }.frame(height: 120).clipped()
                HStack {
                    Text(L("第 \(index + 1) 帧"))
                    Spacer()
                    Text(time, format: .number.precision(.fractionLength(1))) + Text(L(" 秒"))
                }.consoleFont(11).padding(10)
            }.background(Palette.card)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay { SurfaceBorder(color: selected ? Palette.accent : Palette.line, cornerRadius: 7, lineWidth: selected ? 1.5 : 0.5) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(thumbnailError ?? L("单击选择 · ⌘ 点击切换选择 · ⇧ 点击选范围"))
            .task(id: index) {
                do {
                    thumbnailError = nil
                    let image = try await library.thumbnail(at: session.frameURL(at: index))
                    try Task.checkCancellation()
                    thumbnail = image
                } catch is CancellationError {
                } catch { thumbnailError = error.localizedDescription }
            }
            .onDisappear { thumbnail = nil }
    }
}
