import SwiftUI

struct StorageUsageView: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale
    @State private var showDetails = false
    @State private var refreshing = false
    @State private var isHovered = false
    private let imageColor = Color.blue
    private let recordingColor = Color.orange
    private let cacheColor = Color.gray
    private let logColor = Color.purple

    private var usageLabel: String {
        if let usage = library.storageUsage {
            return usage.isComplete ? Self.size(usage.totalBytes) : L("已统计 \(Self.size(usage.totalBytes))")
        }
        return library.storageUsageError == nil ? L("尚未统计") : L("统计失败")
    }

    private var detailLabel: String {
        if library.storageUsageError != nil && library.storageUsage == nil { return L("统计失败，点击查看") }
        if let usage = library.storageUsage, !usage.isComplete { return L("部分文件不可访问") }
        if let maximum = library.storagePolicy.maximumBytes {
            if let usage = library.storageUsage, usage.mediaBytes > maximum { return L("媒体容量已超限") }
            return L("媒体上限 \(Self.size(maximum))")
        }
        if library.storageUsageError != nil { return L("容量管理提示") }
        return L("图片、录屏、缓存与日志")
    }

    var body: some View {
        Button { showDetails = true } label: {
            HStack(spacing: 9) {
                usageRing.frame(width: 24 * fontScale, height: 24 * fontScale)
                VStack(alignment: .leading, spacing: 3) {
                    Text(usageLabel).consoleFont(12, weight: .semibold)
                        .foregroundStyle(Palette.foreground).lineLimit(1)
                    Text(detailLabel).consoleFont(10).foregroundStyle(Palette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").consoleFont(9, weight: .semibold)
                    .foregroundStyle(isHovered ? Palette.accent : Palette.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(Palette.card)
                RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(isHovered ? 0.05 : 0))
            }
            .overlay {
                SurfaceBorder(color: isHovered ? Palette.accent.opacity(0.4) : Palette.line,
                              cornerRadius: 10, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(L("查看保管箱容量"))
        .task { await library.refreshStorageUsage() }
        .popover(isPresented: $showDetails, arrowEdge: .trailing) { details }
        .onChange(of: showDetails) { _, isPresented in
            if isPresented { refresh() }
        }
        .focusEffectDisabled()
    }

    private var usageRing: some View {
        ZStack {
            Circle().strokeBorder(Palette.line, lineWidth: 3 * fontScale)
            if let usage = library.storageUsage, usage.totalBytes > 0 {
                let total = Double(usage.totalBytes)
                let images = Double(usage.imageBytes) / total
                let recordings = Double(usage.recordingBytes) / total
                let cache = Double(usage.cacheBytes) / total
                let logs = Double(usage.logBytes) / total
                Circle().inset(by: 1.5 * fontScale).trim(from: 0, to: images)
                    .stroke(imageColor, lineWidth: 3 * fontScale)
                Circle().inset(by: 1.5 * fontScale).trim(from: images, to: images + recordings)
                    .stroke(recordingColor, lineWidth: 3 * fontScale)
                Circle().inset(by: 1.5 * fontScale).trim(from: images + recordings, to: images + recordings + cache)
                    .stroke(cacheColor, lineWidth: 3 * fontScale)
                Circle().inset(by: 1.5 * fontScale).trim(from: images + recordings + cache, to: images + recordings + cache + logs)
                    .stroke(logColor, lineWidth: 3 * fontScale)
            }
        }
        .rotationEffect(.degrees(-90))
        .accessibilityHidden(true)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("保管箱空间")).consoleFont(14, weight: .semibold)
                Spacer()
                Button(refreshing ? L("统计中…") : L("刷新")) { refresh() }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent).disabled(refreshing)
            }
            if let usage = library.storageUsage {
                HStack {
                    Text(usage.isComplete ? L("总占用") : L("已统计占用")).consoleFont(12)
                    Spacer()
                    Text(Self.size(usage.totalBytes)).consoleFont(14, weight: .medium, design: .monospaced)
                }
                Divider()
                usageRow(L("图片"), bytes: usage.imageBytes, color: imageColor)
                usageRow(L("录屏"), bytes: usage.recordingBytes, color: recordingColor)
                usageRow(L("缓存"), bytes: usage.cacheBytes, color: cacheColor)
                usageRow(L("访问日志"), bytes: usage.logBytes, color: logColor)
                if let maximum = library.storagePolicy.maximumBytes {
                    Divider()
                    HStack {
                        Text(L("媒体容量")).consoleFont(12)
                        Spacer()
                        Text("\(Self.size(usage.mediaBytes)) / \(Self.size(maximum))")
                            .consoleFont(11, design: .monospaced).foregroundStyle(Palette.muted)
                    }
                    ProgressView(value: min(1, Double(usage.mediaBytes) / Double(maximum)))
                        .tint(usage.mediaBytes > maximum ? .orange : Palette.accent)
                    if usage.mediaBytes > maximum {
                        Text(L("媒体容量已超出上限 \(Self.size(usage.mediaBytes - maximum))。"))
                            .consoleFont(11).foregroundStyle(.orange)
                    }
                }
                if !usage.isComplete {
                    Label(L("统计不完整，以下位置无法访问；未读取的文件不计入当前数值。"), systemImage: "exclamationmark.triangle")
                        .consoleFont(11).foregroundStyle(.orange)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(usage.unavailablePaths, id: \.self) { path in
                                Text(path).consoleFont(10, design: .monospaced)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 110 * fontScale)
                }
            } else {
                Text(L("尚无容量统计，可点击刷新读取。"))
                    .consoleFont(12).foregroundStyle(Palette.muted)
            }
            if let error = library.storageUsageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .consoleFont(11).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text(L("图片与录屏共用媒体上限；缓存、访问日志、索引及设置单独统计。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
        }
        .padding(18).frame(width: 330 * max(1, fontScale))
        .foregroundStyle(Palette.foreground).background(Palette.background)
        .focusEffectDisabled()
    }

    private func usageRow(_ title: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title).consoleFont(12)
            Spacer()
            Text(Self.size(bytes)).consoleFont(12, design: .monospaced)
        }
    }

    private func refresh() {
        refreshing = true
        Task {
            await library.refreshStorageUsage(enforceQuota: false)
            refreshing = false
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes == 0 ? L("0 字节") : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
