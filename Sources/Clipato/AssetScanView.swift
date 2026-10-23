import AppKit
import Darwin
import ClipatoCore
import SwiftUI

enum AssetScanMode: Hashable {
    case duplicates, similarImages

    var title: String { self == .duplicates ? L("查找重复文件") : L("查找相似图片") }

    func eligibleAssets(in assets: [CollectionAsset]) -> [CollectionAsset] {
        assets.filter {
            switch $0 {
            case .image: return true
            case .video: return self == .duplicates
            case .session: return false
            }
        }
    }
}

struct AssetScanMenu: View {
    @ObservedObject var model: AppModel
    let assets: [CollectionAsset]
    let selected: Set<CollectionAsset>

    var body: some View {
        let selection = assets.filter { selected.contains($0) }
        let scope = selection.count >= 2 ? selection : assets
        Menu {
            Text(selection.count >= 2 ? L("检测已选 \(scope.count) 项") : L("检测当前列表 \(scope.count) 项"))
            Button(L("查找重复文件")) { model.prepareAssetScan(scope, mode: .duplicates) }
                .disabled(AssetScanMode.duplicates.eligibleAssets(in: scope).count < 2)
            Button(L("查找相似图片")) { model.prepareAssetScan(scope, mode: .similarImages) }
                .disabled(AssetScanMode.similarImages.eligibleAssets(in: scope).count < 2)
        } label: {
            Image(systemName: "square.on.square").consoleFont(12)
                .menuLabel(minimumWidth: 0, padding: 4)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(L("重复与相似检测")).accessibilityLabel(L("重复与相似检测"))
    }
}

func scannedFileValues(at url: URL) throws -> stat {
    var values = stat()
    guard lstat(url.path, &values) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
    guard values.st_mode & S_IFMT == S_IFREG else { throw FileDuplicateError.notRegularFile(url) }
    return values
}

func validateScannedFile(at url: URL, against previous: stat) throws {
    let current = try scannedFileValues(at: url)
    guard current.st_dev == previous.st_dev, current.st_ino == previous.st_ino, current.st_size == previous.st_size,
          current.st_mtimespec.tv_sec == previous.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == previous.st_mtimespec.tv_nsec,
          current.st_ctimespec.tv_sec == previous.st_ctimespec.tv_sec, current.st_ctimespec.tv_nsec == previous.st_ctimespec.tv_nsec else {
        throw NSError(domain: "Clipato", code: 1, userInfo: [
            NSLocalizedDescriptionKey: L("检测后文件已发生变化，请重新检测：\(url.lastPathComponent)")
        ])
    }
}

private func assetScanErrorDescription(_ error: Error) -> String {
    if let imageError = error as? ImageSimilarityError {
        switch imageError {
        case .unreadableImage(let url): return L("无法读取图片：\(url.path)")
        case .pixelAllocation: return L("无法分配图片比较所需的内存。")
        }
    }
    guard let duplicateError = error as? FileDuplicateError else { return error.localizedDescription }
    switch duplicateError {
    case .notRegularFile(let url): return L("不是可读取的普通文件：\(url.path)")
    case .fileChanged(let url): return L("检查期间文件已发生变化，请重新检查：\(url.path)")
    case .readAndCloseFailed(let read, let close):
        return L("\(assetScanErrorDescription(read))；关闭文件失败：\(close.localizedDescription)")
    }
}

struct AssetScanView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    let mode: AssetScanMode
    let assets: [CollectionAsset]
    let externalURLs: [URL]
    @State private var assetsByURL: [URL: CollectionAsset] = [:]
    @State private var fileValues: [URL: stat] = [:]
    @State private var checksums: [URL: String] = [:]
    @State private var duplicateGroups: [DuplicateFileGroup] = []
    @State private var similarMatches: [ImageSimilarityMatch] = []
    @State private var selected: Set<URL> = []
    @State private var removed: Set<URL> = []
    @State private var removedAssets: Set<CollectionAsset> = []
    @State private var running = true
    @State private var progress = 0.0
    @State private var generation = 0
    @State private var error: String?
    @State private var confirmTrash = false
    @State private var deletionTask: Task<Void, Never>?

    init(model: AppModel, library: LibraryStore, mode: AssetScanMode, assets: [CollectionAsset], externalURLs: [URL] = []) {
        self.model = model
        self.library = library
        self.mode = mode
        self.assets = assets
        self.externalURLs = externalURLs
    }

    private var candidateCount: Int { mode == .duplicates ? duplicateGroups.count : similarMatches.count }
    private var selectedCollectionCount: Int {
        let selectedAssets = Set(selected.compactMap { assetsByURL[$0] })
        return library.collectionMembers.values.filter { !$0.isDisjoint(with: selectedAssets) }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(mode == .duplicates
                     ? L("按文件大小、头尾信息及完整 SHA-256 检查，只有字节完全相同才归为重复。")
                     : L("比较图片首帧，识别画质差异和裁剪包含；请查看图片后决定是否移入废纸篓。"))
                    .consoleFont(12).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("\(assets.count + externalURLs.count) 项")).consoleFont(11, weight: .medium)
                    .foregroundStyle(Palette.muted).fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Palette.card, in: Capsule())
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Rectangle().fill(Palette.line).frame(height: 1)
            Group {
                if running {
                    VStack(spacing: 14) {
                        Text(L("正在检测…")).consoleFont(14, weight: .medium)
                        ProgressView(value: progress).frame(maxWidth: 320)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("asset-scan-running")
                } else if error != nil, candidateCount == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").consoleFont(26)
                        Text(L("检测未完成")).consoleFont(14, weight: .medium)
                    }
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    results.disabled(model.scanDeletionInProgress)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error {
                Text(error).consoleFont(12).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.bottom, 14)
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background).foregroundStyle(Palette.foreground).tint(Palette.accent)
        .environment(\.locale, LanguageSettings.shared.locale).focusEffectDisabled()
        .accessibilityIdentifier("asset-scan-page")
        .task(id: generation) { await scan() }
        .onDisappear { deletionTask?.cancel() }
        .confirmationDialog(L("将选中的 \(selected.count) 项移入系统废纸篓？"), isPresented: $confirmTrash, titleVisibility: .visible) {
            Button(L("移入废纸篓"), role: .destructive) { trashSelection() }
        } message: {
            if selectedCollectionCount > 0 {
                Text(L("所选内容涉及 \(selectedCollectionCount) 个收藏夹，移入废纸篓后将从这些收藏夹中一并移除。"))
            } else { Text(L("原文件将移入系统废纸篓。")) }
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                selectionControls.fixedSize()
                Spacer(minLength: 0)
                scanControls.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                selectionControls
                HStack {
                    Spacer(minLength: 0)
                    scanControls
                }
            }
        }
        .disabled(model.scanDeletionInProgress)
        .padding(.horizontal, 24).padding(.vertical, 14)
        .background(Palette.card)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var selectionControls: some View {
        HStack(spacing: 10) {
            if model.scanDeletionInProgress { ProgressView().controlSize(.small) }
            if !running, mode == .duplicates, duplicateGroups.contains(where: { $0.urls.filter { !removed.contains($0) }.count >= 2 }) {
                Button(L("勾选重复副本")) {
                    selected = Set(duplicateGroups.flatMap { $0.urls.filter { !removed.contains($0) }.dropFirst() })
                }
                .buttonStyle(QuietButtonStyle())
                .help(L("每组保留列表中第一项，勾选其余副本；移入废纸篓前仍需确认。"))
            }
            if !selected.isEmpty {
                Button(L("取消选择")) { selected = [] }.buttonStyle(QuietButtonStyle())
                Text(L("已选 \(selected.count) 项")).consoleFont(11).foregroundStyle(Palette.muted)
            }
        }
    }

    private var scanControls: some View {
        HStack(spacing: 8) {
            Button(running ? L("取消") : L("返回上一步")) {
                if running { model.selectAssetScan(mode) }
                else { model.returnToImageProcessingInput() }
            }
                .buttonStyle(QuietButtonStyle())
            if !running {
                Button(L("重新检测")) { generation += 1 }.buttonStyle(QuietButtonStyle())
            }
            Button(role: .destructive) { confirmTrash = true } label: {
                Label(L("移入废纸篓"), systemImage: "trash")
            }
            .buttonStyle(QuietButtonStyle()).disabled(selected.isEmpty || running)
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mode == .duplicates ? L("找到 \(candidateCount) 组候选") : L("找到 \(candidateCount) 对候选"))
                    .consoleFont(12, weight: .medium)
                    .accessibilityIdentifier("asset-scan-summary")
                Spacer()
                if !removed.isEmpty {
                    Text(L("已移入废纸篓 \(removed.count) 项")).consoleFont(11).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 24).padding(.top, 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if candidateCount == 0 {
                        Text(mode == .duplicates ? L("未发现重复文件") : L("未发现相似图片"))
                            .consoleFont(12).foregroundStyle(Palette.muted)
                            .frame(maxWidth: .infinity, minHeight: 250)
                    } else if mode == .duplicates {
                        ForEach(Array(duplicateGroups.enumerated()), id: \.offset) { index, group in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(L("第 \(index + 1) 组 · 完全相同")).consoleFont(12, weight: .medium)
                                Text("SHA-256 · \(group.sha256)").consoleFont(10, design: .monospaced)
                                    .foregroundStyle(Palette.muted).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(group.urls, id: \.self) { fileRow($0) }
                            }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { SurfaceBorder(cornerRadius: 8) }
                        }
                    } else {
                        ForEach(Array(similarMatches.enumerated()), id: \.offset) { _, match in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(matchTitle(match)).consoleFont(12, weight: .medium)
                                    Spacer()
                                    Text(match.score, format: .percent.precision(.fractionLength(0)))
                                        .consoleFont(11).monospacedDigit().foregroundStyle(Palette.muted)
                                }
                                fileRow(match.first)
                                fileRow(match.second)
                            }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                                .overlay { SurfaceBorder(cornerRadius: 8) }
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityIdentifier("asset-scan-results")
    }

    private func matchTitle(_ match: ImageSimilarityMatch) -> String {
        switch match.kind {
        case .similar: return L("相似图片")
        case .firstContainsSecond: return L("第一张包含第二张")
        case .secondContainsFirst: return L("第二张包含第一张")
        }
    }

    @ViewBuilder private func fileRow(_ url: URL) -> some View {
        if removed.contains(url) {
            HStack {
                Image(systemName: "trash")
                Text(url.lastPathComponent).strikethrough().lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(L("已移入废纸篓"))
            }.consoleFont(11).foregroundStyle(Palette.muted).padding(.vertical, 8)
        } else {
            ScanFileRow(library: library, url: url, asset: assetsByURL[url], bytes: fileValues[url]!.st_size,
                        selected: Binding(get: { selected.contains(url) }, set: {
                            if $0 { selected.insert(url) } else { selected.remove(url) }
                        }))
        }
    }

    private func scan() async {
        running = true
        progress = 0
        error = nil
        selected = []
        duplicateGroups = []
        similarMatches = []
        fileValues = [:]
        checksums = [:]
        do {
            let images = Dictionary(uniqueKeysWithValues: library.images.map { ($0.id, $0) })
            let videos = Set(library.videos)
            var urls = externalURLs.filter { !removed.contains($0) }
            var references: [URL: CollectionAsset] = [:]
            for asset in assets {
                if removedAssets.contains(asset) { continue }
                let url: URL
                switch asset {
                case .image(let id):
                    guard let image = images[id] else { throw CollectionError.missingAsset }
                    url = library.imageURL(image)
                case .video(let video):
                    guard videos.contains(video) else { throw CollectionError.missingAsset }
                    url = video
                case .session: throw CollectionError.missingAsset
                }
                urls.append(url)
                references[url] = asset
            }
            assetsByURL = references
            let mode = mode
            let scanURLs = urls
            let generation = generation
            let worker = Task.detached(priority: .utility) {
                var values: [URL: stat] = [:]
                for url in scanURLs { try Task.checkCancellation(); values[url] = try scannedFileValues(at: url) }
                let report: @Sendable (Int, Int) -> Void = { completed, total in
                    if completed == total || completed % max(1, total / 100) == 0 {
                        Task { @MainActor in
                            guard self.generation == generation, running else { return }
                            progress = Double(completed) / Double(max(1, total))
                        }
                    }
                }
                let groups = mode == .duplicates ? try FileDuplicateStep.execute(urls: scanURLs, progress: report) : []
                let matches = mode == .similarImages ? try ImageSimilarityStep.execute(urls: scanURLs, progress: report) : []
                let matchedURLs = Set(matches.flatMap { [$0.first, $0.second] })
                var checksums: [URL: String] = [:]
                for url in scanURLs where matchedURLs.contains(url) {
                    try Task.checkCancellation()
                    checksums[url] = try FileDuplicateStep.sha256(at: url)
                }
                for url in scanURLs { try Task.checkCancellation(); try validateScannedFile(at: url, against: values[url]!) }
                let candidates = matchedURLs.union(groups.flatMap(\.urls))
                return (groups, matches, values.filter { candidates.contains($0.key) }, checksums)
            }
            let (groups, matches, values, hashes) = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            duplicateGroups = groups
            similarMatches = matches
            fileValues = values
            checksums = hashes
        } catch is CancellationError {
            return
        } catch { self.error = assetScanErrorDescription(error) }
        running = false
    }

    private func trashSelection() {
        model.scanDeletionInProgress = true
        error = nil
        deletionTask = Task { @MainActor in
            defer { model.scanDeletionInProgress = false; deletionTask = nil }
            do {
                let urls = selected.sorted { $0.path < $1.path }
                let verification: [DuplicateFileGroup]
                if mode == .duplicates {
                    verification = duplicateGroups.filter { $0.urls.contains(where: selected.contains) }.map {
                        DuplicateFileGroup(urls: $0.urls.filter { !removed.contains($0) }, fileSize: $0.fileSize, sha256: $0.sha256)
                    }
                } else {
                    let pairs = similarMatches.filter { selected.contains($0.first) || selected.contains($0.second) }
                    let involved = Set(pairs.flatMap { [$0.first, $0.second] }).subtracting(removed)
                    verification = involved.map {
                        DuplicateFileGroup(urls: [$0], fileSize: fileValues[$0]!.st_size, sha256: checksums[$0]!)
                    }
                }
                let required = Set(verification.flatMap(\.urls))
                let values = fileValues
                let worker = Task.detached(priority: .utility) {
                    for url in required { try Task.checkCancellation(); try validateScannedFile(at: url, against: values[url]!) }
                    try FileDuplicateStep.verify(groups: verification)
                }
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                for start in stride(from: 0, to: urls.count, by: 32) {
                    let batch = Array(urls[start..<min(start + 32, urls.count)])
                    let batchURLs = Set(batch)
                    let related = Set(verification.filter { $0.urls.contains(where: batchURLs.contains) }.flatMap(\.urls)).subtracting(removed)
                    for url in related { try validateScannedFile(at: url, against: fileValues[url]!) }
                    do {
                        defer { recordRemovedFiles(batch) }
                        if externalURLs.isEmpty {
                            try model.trashScannedAssets(batch.map { (assetsByURL[$0]!, $0) })
                        } else {
                            try model.trashScannedFiles(batch)
                        }
                    }
                    await Task.yield()
                    try Task.checkCancellation()
                }
            } catch is CancellationError {
                return
            } catch { self.error = assetScanErrorDescription(error) }
        }
    }

    private func recordRemovedFiles(_ urls: [URL]) {
        let images = Set(library.images.map(\.id))
        let videos = Set(library.videos)
        for url in urls {
            guard let asset = assetsByURL[url] else {
                if !model.externalScanURLs.contains(url) {
                    removed.insert(url)
                    selected.remove(url)
                }
                continue
            }
            let exists: Bool
            switch asset {
            case .image(let id): exists = images.contains(id)
            case .video(let video): exists = videos.contains(video)
            case .session: exists = true
            }
            if !exists {
                removed.insert(url)
                removedAssets.insert(asset)
                selected.remove(url)
            }
        }
    }
}

private struct ScanFileRow: View {
    @ObservedObject var library: LibraryStore
    let url: URL
    let asset: CollectionAsset?
    let bytes: Int64
    @Binding var selected: Bool
    @State private var thumbnail: NSImage?
    @State private var thumbnailError: String?
    @State private var showPreview = false
    private var isImage: Bool {
        guard let asset else { return true }
        if case .image = asset { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            Toggle(L("选择文件"), isOn: $selected).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(url.lastPathComponent)
            Button {
                if isImage { showPreview.toggle() } else { NSWorkspace.shared.open(url) }
            } label: {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .background(ImagePreviewSource(url: url, image: thumbnail))
                    }
                    else { Image(systemName: isImage ? "photo" : "film").foregroundStyle(Palette.muted) }
                }.frame(width: 96, height: 70).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L("预览"))
                .background(SystemImagePreview(url: Binding(get: { showPreview ? url : nil }, set: { showPreview = $0 != nil })))
            VStack(alignment: .leading, spacing: 5) {
                Text(url.lastPathComponent).consoleFont(12, weight: .medium).lineLimit(1).truncationMode(.middle).help(url.path)
                Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                if let asset {
                    let collections = library.collections(containing: asset)
                    if !collections.isEmpty {
                        Label(collections.map(\.name).joined(separator: " · "), systemImage: "folder")
                            .consoleFont(11).foregroundStyle(Palette.accent).lineLimit(1)
                            .help(collections.map(\.name).joined(separator: "\n"))
                    }
                }
                if let thumbnailError { Text(thumbnailError).consoleFont(10).foregroundStyle(.red).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                .buttonStyle(.borderless).help(L("在 Finder 中显示")).accessibilityLabel(L("在 Finder 中显示"))
        }
        .task(id: url) {
            thumbnail = nil
            thumbnailError = nil
            guard isImage else { return }
            do {
                let image = try await library.thumbnail(at: url)
                try Task.checkCancellation()
                thumbnail = image
            }
            catch is CancellationError { return }
            catch { thumbnailError = error.localizedDescription }
        }
        .onDisappear { thumbnail = nil; thumbnailError = nil; showPreview = false }
    }
}
