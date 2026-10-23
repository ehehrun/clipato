import AppKit
import ClipatoCore
import SwiftUI

struct LongScreenshotView: View {
    let onSave: (CGImage, AssetTag?) throws -> Void
    let onClose: () -> Void
    @Environment(\.displayScale) private var displayScale
    private let sourceImages: [CGImage]
    @Binding private var order: [Int]
    @Binding private var tag: AssetTag?
    @Bindable private var state: LongScreenshotState
    let onChange: () -> Void

    init(images: [CGImage], order: Binding<[Int]>, tag: Binding<AssetTag?>, state: LongScreenshotState,
         onSave: @escaping (CGImage, AssetTag?) throws -> Void, onClose: @escaping () -> Void,
         onChange: @escaping () -> Void) {
        sourceImages = images
        _order = order
        _tag = tag
        self.state = state
        self.onSave = onSave
        self.onClose = onClose
        self.onChange = onChange
    }

    private var images: [CGImage] { state.images }

    private var unresolvedCount: Int {
        state.analyses.filter { if case .matched = $0 { return false }; return true }.count
    }
    private var duplicateFrames: Set<Int> {
        Set(state.analyses.indices.filter { state.analyses[$0] == .duplicate }.map { $0 + 1 })
    }
    private var minimumZoom: CGFloat { 1 / max(1, max(state.canvasSize.width, state.canvasSize.height)) }
    private var canExport: Bool { !state.isWorking && !state.placements.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Text(L("容错 0–")).font(.caption)
                TextField(L("上限"), value: $state.maximumOverlap, format: .number.grouping(.never))
                    .environment(\.isFocusEffectEnabled, true)
                    .textFieldStyle(.plain).padding(.horizontal, 7).frame(width: 65, height: 28)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { SurfaceBorder(cornerRadius: 6) }
                    .disabled(state.isWorking)
                    .accessibilityLabel(L("自动拼接的重叠上限"))
                Text("px").font(.caption).foregroundStyle(Palette.muted)
                if state.alignmentUndo != nil {
                    Button(L("撤销拼接"), action: undoAlignment).disabled(state.isWorking)
                        .help(L("恢复本次自动拼接前的图片位置"))
                }
                Button(L("自动拼接")) { align() }
                    .disabled(state.isWorking || images.count < 2)
                    .help(L("在 0 到容错上限内尝试拼合；有共同内容时重合对齐，0 px 表示直接顺接。"))
            }
            .controlSize(.small).buttonStyle(QuietButtonStyle())
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                frameList.frame(width: 235)
                Divider()
                preview
            }
            Divider()
            footer
        }
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .tint(Palette.accent)
        .onAppear {
            state.reconcile(images: sourceImages, order: order)
            if !state.hasStartedInitialStitch {
                if images.count > 1 { align(initial: true) }
                else { state.hasStartedInitialStitch = true }
            }
        }
        .onChange(of: order) { state.reconcile(images: sourceImages, order: order) }
        .onDisappear { state.cancelWork() }
        .environment(\.locale, LanguageSettings.shared.locale)
        .focusEffectDisabled()
    }

    private var frameList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("截图与接缝")).font(.subheadline.weight(.medium))
                Spacer()
                Button(L("取消选择"), action: clearSelection)
                    .font(.caption).disabled(!state.showsSelection)
                if !duplicateFrames.isEmpty {
                    Button(L("删除重复帧")) { removeFrames(duplicateFrames) }
                        .font(.caption).disabled(state.isWorking)
                }
            }.padding(12)
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 8) {
                            ForEach(images.indices, id: \.self) { frameRow($0) }
                        }.padding(.horizontal, 10)
                        Color.clear.frame(minHeight: 24)
                    }.frame(minHeight: geometry.size.height, alignment: .top)
                        .background {
                            Color.clear.contentShape(Rectangle()).onTapGesture(perform: clearSelection)
                        }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if !state.showsSelection {
                    Text(L("查看拼图")).font(.system(size: 12, weight: .medium))
                    Text(L("当前没有选中图片。点击图片或左侧卡片可继续调整；点击空白处可取消选择。"))
                        .font(.caption).foregroundStyle(Palette.muted).lineSpacing(3)
                } else if let selectedJoinIndex = state.selectedJoin {
                    Text(L("截图 \(selectedJoinIndex + 2) · 与上一张的接缝"))
                        .font(.system(size: 12, weight: .medium))
                    seamControls(selectedJoinIndex)
                    Text(L("拖动图片或用方向键移动，每次 1 px，Shift 每次 10 px。重叠为负数时留出间隙。"))
                        .font(.caption).foregroundStyle(Palette.muted).lineSpacing(3)
                } else {
                    Text(L("截图 1")).font(.system(size: 12, weight: .medium))
                    Text(L("拖动图片或用方向键移动，每次 1 px，Shift 每次 10 px。其他图片保持原位。"))
                        .font(.caption).foregroundStyle(Palette.muted).lineSpacing(3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .background(Palette.sidebar)
    }

    private func frameRow(_ index: Int) -> some View {
        let selected = state.showsSelection && index == (state.selectedJoin.map { $0 + 1 } ?? 0)
        return HStack(spacing: 0) {
            Button {
                if selected { clearSelection() }
                else {
                    state.selectImage(at: index)
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Label(L("截图 \(index + 1)"), systemImage: index == 0 ? "photo" : "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(images[index].width) × \(images[index].height) px")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                    if index == 0 {
                        Text(L("第一张")).font(.caption).foregroundStyle(Palette.muted)
                    } else {
                        seamStatus(index - 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("选择截图 \(index + 1)"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button { removeFrames([index]) } label: {
                Image(systemName: "trash").frame(width: 30, height: 34).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).disabled(state.isWorking || images.count < 2)
            .help(L("删除截图 \(index + 1)")).accessibilityLabel(L("删除截图 \(index + 1)"))
            .padding(.trailing, 4)
        }
        .background(selected ? Palette.accent.opacity(0.08) : Palette.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            SurfaceBorder(color: selected ? Palette.accent : Palette.line, cornerRadius: 7, lineWidth: selected ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func seamStatus(_ index: Int) -> some View {
        switch state.analyses[index] {
        case .matched(let join):
            Label(join.confidence == nil ? L("手动调整") : L("已按内容对齐"), systemImage: join.confidence == nil ? "hand.draw" : "checkmark.circle")
                .font(.caption).foregroundStyle(Palette.muted)
            if join.confidence != nil {
                Text(L("横移 \(join.offsetX) · 纵移 \(images[index].height - join.overlap) px"))
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
            }
        case .duplicate:
            Label(L("与上一张重复"), systemImage: "square.on.square")
                .font(.caption).foregroundStyle(Palette.accent)
        case .noReliableMatch:
            Label(state.joins[index].overlap == 0 && state.joins[index].offsetX == 0 ? L("顺接 · 0 px") : L("自由摆放"), systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }

    private func seamControls(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            seamStatus(index)
            HStack(spacing: 5) {
                Text(L("重叠")).font(.caption)
                TextField(L("重叠像素"), value: Binding(get: { state.joins[index].overlap }, set: { value in
                    var join = state.joins[index]; join.overlap = value; adjust(join, at: index)
                }), format: .number.grouping(.never))
                    .environment(\.isFocusEffectEnabled, true)
                    .textFieldStyle(.roundedBorder).frame(width: 63)
                Text("px").font(.caption).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 5) {
                Text(L("横移")).font(.caption)
                TextField(L("水平偏移像素"), value: Binding(get: { state.joins[index].offsetX }, set: { value in
                    var join = state.joins[index]; join.offsetX = value; adjust(join, at: index)
                }), format: .number.grouping(.never))
                    .environment(\.isFocusEffectEnabled, true)
                    .textFieldStyle(.roundedBorder).frame(width: 63)
                Text("px").font(.caption).foregroundStyle(Palette.muted)
            }
            if case .matched = state.analyses[index] {} else {
                Button(L("确认当前接缝")) { adjust(state.joins[index], at: index) }
                    .font(.caption).help(L("将这个接缝确认为手动设置"))
            }
        }.disabled(state.isWorking)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { setZoom(state.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help(L("缩小预览")).accessibilityLabel(L("缩小预览")).disabled(state.zoom <= minimumZoom)
                Text(state.zoom, format: .percent.precision(.fractionLength(0...1)))
                    .font(.caption.monospacedDigit()).frame(minWidth: 45)
                Button { setZoom(state.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help(L("放大预览")).accessibilityLabel(L("放大预览")).disabled(state.zoom >= 32)
                Divider().frame(height: 16).padding(.horizontal, 3)
                Button("100%") {
                    setZoom(1)
                    state.viewportResetRequest += 1
                }.help(L("恢复 100% 真实像素并居中：1 个图片像素对应 1 个屏幕物理像素"))
                    .accessibilityLabel(L("原比例"))
                Button {
                    state.fitsWindow = true
                    state.viewportResetRequest += 1
                } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .help(L("完整显示当前拼图，并随窗口大小调整预览"))
                    .accessibilityLabel(L("适合窗口"))
                Spacer(minLength: 4)
                if !state.placements.isEmpty {
                    Text("\(Int(state.canvasSize.width)) × \(Int(state.canvasSize.height)) px")
                        .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                }
            }
            .controlSize(.small).buttonStyle(QuietButtonStyle())
            .padding(.horizontal, 12).padding(.vertical, 8).background(Palette.card)
            Divider()
            GeometryReader { geometry in
                ZStack {
                    Palette.canvas
                    if !state.placements.isEmpty {
                        LongScreenshotPreview(images: images, placements: state.placements, canvasSize: state.canvasSize,
                                              selectedJoin: state.selectedJoin, showsSelection: state.showsSelection, displayScale: displayScale,
                                              zoom: Binding(get: { state.zoom }, set: setZoom), minimumZoom: minimumZoom, focusRequest: state.focusRequest,
                                              resetRequest: state.viewportResetRequest,
                                              isEnabled: !state.isWorking, preservesViewport: !state.fitsWindow,
                                              onSelect: { state.selectedJoin = $0; state.showsSelection = true }, onDeselect: clearSelection,
                                              onNudge: nudge, onMove: move,
                                              onBeginMove: { state.fitsWindow = false })
                    }
                    if state.isWorking { ProgressView().padding(16).background(Palette.card, in: RoundedRectangle(cornerRadius: 9)) }
                }
                .onAppear { updateFit(geometry.size) }
                .onChange(of: geometry.size) { updateFit(geometry.size) }
                .onChange(of: state.canvasSize) { updateFit(geometry.size) }
                .onChange(of: displayScale) { updateFit(geometry.size) }
                .onChange(of: state.fitsWindow) { updateFit(geometry.size) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            if let message = state.error { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if state.isWorking {
                Text(L("正在处理图片，请稍候…")).font(.caption).foregroundStyle(Palette.muted)
            } else if let message = state.alignmentMessage {
                Text(message).font(.caption).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if unresolvedCount > 0 {
                Label(L("可自由移动每张图片；自动拼接仅作辅助，拷贝和保存使用当前布局。"), systemImage: "hand.draw")
                    .font(.caption).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                if state.copied {
                    Text(L("已拷贝图片")).font(.caption).foregroundStyle(Palette.muted)
                }
                Menu {
                    AssetTagActions(selected: [tag]) { tag = $0 }
                } label: {
                    Group {
                        if let tag { AssetTagLabel(tag: tag) }
                        else { Label(L("标签"), systemImage: "tag") }
                    }.menuLabel()
                }.menuStyle(.borderlessButton).fixedSize().disabled(state.isWorking)
                Button { export(save: false) } label: { Image(systemName: "doc.on.doc") }
                    .disabled(!canExport).help(L("拷贝")).accessibilityLabel(L("拷贝"))
                Button(L("导出到保管箱")) { export(save: true) }
                    .buttonStyle(AccentButtonStyle()).disabled(!canExport)
            }.controlSize(.small).buttonStyle(QuietButtonStyle())
        }.padding(.horizontal, 12).padding(.vertical, 8).background(Palette.card)
    }

    private func align(initial: Bool = false) {
        guard !state.isWorking, images.count > 1 else { return }
        guard (0...CollageRenderer.maximumCanvasDimension).contains(state.maximumOverlap) else {
            state.error = L("容错上限应为 0 到 \(CollageRenderer.maximumCanvasDimension) px。")
            return
        }
        state.error = nil
        state.copied = false
        state.alignmentMessage = nil
        let workID = state.beginWork(initialStitch: initial)
        let images = images
        let originalJoins = state.joins
        let originalAnalyses = state.analyses
        let maximum = state.maximumOverlap
        let worker = Task.detached(priority: .userInitiated) {
            var results: [LongScreenshotAnalysis] = []
            for index in originalJoins.indices {
                try Task.checkCancellation()
                results.append(try LongScreenshot.analyze(previous: images[index], next: images[index + 1], maximumOverlap: maximum))
            }
            let aligned = try LongScreenshot.aligning(joins: originalJoins, analyses: results, joinUnmatched: true)
            let layout = try LongScreenshot.layout(images: images, joins: aligned)
            return (results, aligned, layout)
        }
        state.workTask = Task { @MainActor in
            defer { state.finishWork(workID) }
            do {
                let (results, aligned, layout) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                var matched = 0
                let changed = zip(originalJoins, aligned).contains {
                    $0.overlap != $1.overlap || $0.offsetX != $1.offsetX
                }
                var duplicates = 0
                for analysis in results {
                    if case .matched = analysis {
                        matched += 1
                    } else if analysis == .duplicate { duplicates += 1 }
                }
                if changed {
                    state.alignmentUndo = (originalJoins, originalAnalyses)
                    state.fitsWindow = true
                }
                state.joins = aligned
                state.analyses = results
                state.canvasSize = layout.size
                state.placements = layout.placements
                onChange()
                let unmatched = results.count - matched - duplicates
                var messages: [String] = []
                if matched > 0 { messages.append(L("已在 0–\(maximum) px 内对齐 \(matched) 处重叠")) }
                if duplicates > 0 { messages.append(L("\(duplicates) 处图片重复，已保留原图")) }
                if unmatched > 0 { messages.append(L("\(unmatched) 处采用 0 px 顺接")) }
                state.alignmentMessage = messages.joined(separator: "；") + "。"
            } catch is CancellationError { return }
            catch { state.error = workspaceErrorDescription(error) }
        }
    }

    private func undoAlignment() {
        guard !state.isWorking, let previous = state.alignmentUndo else { return }
        state.joins = previous.joins
        state.analyses = previous.analyses
        state.alignmentUndo = nil
        state.copied = false
        state.alignmentMessage = L("已恢复自动拼接前的位置。")
        state.fitsWindow = true
        refreshLayout()
        onChange()
    }

    private func refreshLayout() {
        do {
            let result = try LongScreenshot.layout(images: images, joins: state.joins)
            state.canvasSize = result.size
            state.placements = result.placements
            state.error = nil
        } catch {
            state.placements = []
            state.canvasSize = .zero
            state.error = workspaceErrorDescription(error)
        }
    }

    private func adjust(_ value: LongScreenshotJoin, at index: Int) {
        guard !state.isWorking else { return }
        var value = value
        value.confidence = nil
        var next = state.joins
        next[index] = value
        let result: (size: CGSize, placements: [CollagePlacement])?
        do {
            result = try LongScreenshot.layout(images: images, joins: next)
            state.error = nil
        } catch let failure as CollageError {
            guard case .canvasTooLarge = failure else { state.error = workspaceErrorDescription(failure); return }
            // Keep legal seam edits so several overlaps can bring an oversized draft back within the export limit.
            result = nil
            state.error = workspaceErrorDescription(failure)
        } catch { state.error = workspaceErrorDescription(error); return }
        state.joins = next
        state.analyses[index] = .matched(value)
        state.fitsWindow = false
        state.selectedJoin = index
        state.showsSelection = true
        state.copied = false
        state.alignmentMessage = nil
        state.alignmentUndo = nil
        if let result {
            state.canvasSize = result.size
            state.placements = result.placements
        } else {
            state.canvasSize = .zero
            state.placements = []
        }
        onChange()
    }

    private func nudge(_ horizontal: Int, _ vertical: Int) {
        guard state.showsSelection else { return }
        move(state.selectedJoin.map { $0 + 1 } ?? 0, horizontal, vertical)
    }

    private func clearSelection() {
        state.selectImage(at: nil)
    }

    private func move(_ imageIndex: Int, _ horizontal: Int, _ vertical: Int) {
        guard !state.isWorking else { return }
        do {
            let next = try LongScreenshot.moving(joins: state.joins, imageIndex: imageIndex, dx: horizontal, dy: vertical)
            let layout = try LongScreenshot.layout(images: images, joins: next)
            for index in state.joins.indices where next[index] != state.joins[index] { state.analyses[index] = .matched(next[index]) }
            state.joins = next
            state.placements = layout.placements
            state.canvasSize = layout.size
            state.selectedJoin = imageIndex == 0 ? nil : imageIndex - 1
            state.showsSelection = true
            state.fitsWindow = false
            state.copied = false
            state.alignmentMessage = nil
            state.alignmentUndo = nil
            state.error = nil
            onChange()
        } catch { state.error = workspaceErrorDescription(error) }
    }

    private func removeFrames(_ removed: Set<Int>) {
        guard !state.isWorking else { return }
        let retained = order.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        guard !retained.isEmpty else { return }
        order = retained
        state.reconcile(images: sourceImages, order: retained)
        onChange()
    }

    private func export(save: Bool) {
        guard canExport else { return }
        let workID = state.beginWork()
        state.error = nil
        let images = images
        let exportJoins = state.joins
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try LongScreenshot.render(images: images, joins: exportJoins)
        }
        state.workTask = Task { @MainActor in
            defer { state.finishWork(workID) }
            do {
                let image = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                if save {
                    try onSave(image, tag)
                    state.isWorking = false
                    onClose()
                } else {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))]) else {
                        throw LongScreenshotError.invalidSetting(L("无法写入图片剪贴板，请重试。"))
                    }
                    state.copied = true
                }
            } catch is CancellationError { return }
            catch { state.error = workspaceErrorDescription(error) }
        }
    }

    private func setZoom(_ value: CGFloat) {
        state.fitsWindow = false
        state.zoom = min(max(value, minimumZoom), 32)
    }

    private func updateFit(_ size: CGSize) {
        guard state.fitsWindow, state.canvasSize.width > 0, state.canvasSize.height > 0 else { return }
        state.zoom = max(minimumZoom, min(1, min(max(1, size.width - 32) * displayScale / state.canvasSize.width,
                                          max(1, size.height - 32) * displayScale / state.canvasSize.height)))
    }
}
