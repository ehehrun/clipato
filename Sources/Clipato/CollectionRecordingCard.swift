import AppKit
import SwiftUI

struct CollectionRecordingCard: View {
    let library: LibraryStore
    let session: SavedSession?
    var videoURL: URL? = nil
    var thumbnailVersion = 0
    let title: String
    let detail: String
    let fileInfo: AssetFileInfo?
    let tag: AssetTag?
    let selected: Bool
    var displayMode: VaultDisplayMode = .standard
    var collections: [AssetCollection] = []
    let toggle: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void
    @State private var thumbnail: NSImage?
    @State private var thumbnailError: String?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var recordingTitle: String { session == nil ? L("完整视频") : L("关键帧录屏") }
    private var recordingSymbol: String { session == nil ? "play.rectangle.fill" : "rectangle.stack.fill" }

    private var cornerRadius: CGFloat { displayMode == .standard ? 8 : 0 }
    private var borderWidth: CGFloat { selected ? 1.5 : (displayMode == .imagesOnly ? 1 : 0.5) }
    private var helpText: String {
        if let thumbnailError { return thumbnailError }
        let membership = collections.isEmpty ? "" : L("已加入：\(collections.map(\.name).joined(separator: "、"))\n")
        return title + "\n" + detail + "\n" + membership
            + L("单击选择 · ⌘ 点击切换选择 · ⇧ 点击选范围 · ⌘A 全选 · 双击播放")
    }

    var body: some View {
        decoratedCard
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture(perform: select)
            .simultaneousGesture(TapGesture(count: 2).onEnded(open))
            .accessibilityLabel("\(title) · \(recordingTitle)")
            .accessibilityValue(detail)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(helpText)
            .task(id: videoURL.map { "\($0.absoluteString)#\(thumbnailVersion)" } ?? session?.directory.absoluteString) {
                await loadThumbnail()
            }
            .onDisappear { thumbnail = nil; isHovered = false }
    }

    private var decoratedCard: some View {
        cardContent
            .background(displayMode == .standard ? Palette.card : .clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                SurfaceBorder(color: selected ? Palette.accent : Palette.line,
                              cornerRadius: cornerRadius, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailArea
                .clipped()
                .overlay(alignment: .topLeading) { membershipBadge }
                .overlay(alignment: .bottomLeading) { recordingBadge }
            if displayMode == .standard { metadata }
        }
    }

    private var membershipBadge: some View {
        CollectionMembershipBadge(collections: collections)
            .padding(.leading, 8).padding(.trailing, 38).padding(.top, 8)
            .opacity(displayMode == .standard || isHovered ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .allowsHitTesting(false)
            .accessibilityHidden(displayMode == .imagesOnly && !isHovered)
    }

    private var recordingBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: recordingSymbol)
            if let session {
                Text(RecordingView.time(session.manifest.duration)).monospacedDigit()
            }
        }.consoleFont(12, weight: .medium)
            .foregroundStyle(Palette.foreground)
            .padding(5)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 4))
            .padding(8)
            .help(recordingTitle)
            .accessibilityLabel(recordingTitle)
            .allowsHitTesting(false)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let tag {
                    Circle().fill(tag.color).frame(width: 8, height: 8)
                        .help(L("\(tag.title)标签")).accessibilityLabel(L("\(tag.title)标签"))
                }
                Text(title).consoleFont(11, weight: .medium).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(detail).consoleFont(9).lineLimit(1)
                Spacer()
                Text(fileInfo?.label ?? L("读取大小…")).consoleFont(10).fixedSize()
                    .help(fileInfo?.help ?? L("正在读取文件大小"))
            }.foregroundStyle(Palette.muted).padding(.vertical, 2)
        }.padding(11)
    }

    private func select() {
        if let event = NSApp.currentEvent, event.type == .leftMouseUp, event.clickCount > 1 { return }
        toggle(NSApp.currentEvent?.modifierFlags ?? [])
    }

    private func loadThumbnail() async {
        thumbnail = nil
        thumbnailError = nil
        do {
            let image: NSImage
            if let session, !session.manifest.frames.isEmpty {
                image = try await library.thumbnail(at: session.frameURL(at: 0))
            } else if let videoURL {
                image = try await library.videoThumbnail(at: videoURL)
            } else {
                return
            }
            try Task.checkCancellation()
            thumbnail = image
        } catch is CancellationError {
        } catch { thumbnailError = error.localizedDescription }
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
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .padding(displayMode == .standard ? 10 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: thumbnailError != nil ? "exclamationmark.triangle" : recordingSymbol)
                    .consoleFont(30, weight: .light).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill").consoleFont(18).foregroundStyle(Palette.accent)
                    .background(Palette.card, in: Circle()).padding(9)
            }
        }
    }
}
