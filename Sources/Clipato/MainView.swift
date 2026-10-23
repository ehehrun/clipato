import SwiftUI
import AppKit

struct MainView: View {
    @ObservedObject var model: AppModel
    private let appearance = AppearanceSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRecording = false
    @AppStorage("sidebarWidth") private var preferredSidebarWidth = 216.0
    @State private var sidebarDragWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let scale = max(1, appearance.consoleFontSize.scale)
            let minimumWidth = 180 * scale
            let maximumWidth = max(minimumWidth, min(420 * scale, geometry.size.width - 641))
            let width = min(max(sidebarDragWidth ?? CGFloat(preferredSidebarWidth) * scale, minimumWidth), maximumWidth)
            HStack(spacing: 0) {
                sidebar.frame(width: width)
                Divider()
                VStack(spacing: 0) {
                    if model.section != .shortcuts { header }
                    ZStack {
                        // Retain the active tool when browsing another section, including its scan task and results.
                        if let library = model.library, model.section == .imageProcessing || model.imageProcessingRoute != nil {
                            ImageProcessingView(model: model, library: library)
                                .opacity(model.section == .imageProcessing ? 1 : 0)
                                .allowsHitTesting(model.section == .imageProcessing)
                                .disabled(model.section != .imageProcessing)
                                .accessibilityHidden(model.section != .imageProcessing)
                        }
                        if model.section == .shortcuts {
                            ShortcutSettingsView(shortcuts: model.shortcuts)
                        } else if model.section == .general {
                            GeneralSettingsView(model: model)
                        } else if model.section == .security {
                            SecuritySettingsView(model: model)
                        } else if model.section == .aiTerminal {
                            AITerminalSettingsView(model: model)
                        } else if model.section == .appearance {
                            AppearanceSettingsView(model: model)
                        } else if let library = model.library {
                            switch model.section {
                            case .images: VaultView(model: model, library: library)
                            case .recordings: RecordingView(model: model, library: library, recorder: model.recorder)
                            case .imageProcessing: EmptyView()
                            case .collections:
                                if let id = model.selectedCollectionID {
                                    CollectionContentView(model: model, library: library, collectionID: id).id(id)
                                } else {
                                    ContentUnavailableView(L("选择收藏夹"), systemImage: "folder", description: Text(L("在侧栏新建收藏夹，或选择已有收藏夹查看内容。")))
                                }
                            case .guide: GuideView(model: model)
                            case .shortcuts, .general, .security, .aiTerminal, .appearance: EmptyView()
                            }
                        } else {
                            VStack {
                                ContentUnavailableView(L("保管箱无法打开"), systemImage: "externaldrive.badge.exclamationmark", description: Text(L("请检查数据目录的权限或 index 文件，错误详情会显示在提示中。")))
                                Button(L("打开数据目录")) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.libraryRoot.path) }
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.top, 24)
            }
            .overlay(alignment: .leading) {
                SidebarResizeHandle(width: width, isEnabled: !model.clearingLibraryData, onResize: { proposed in
                    sidebarDragWidth = min(max(proposed, minimumWidth), maximumWidth)
                }, onResizeEnd: { proposed in
                    preferredSidebarWidth = Double(min(max(proposed, minimumWidth), maximumWidth) / scale)
                    sidebarDragWidth = nil
                })
                .frame(width: SidebarResizeHandle.hitWidth)
                .offset(x: width - (SidebarResizeHandle.hitWidth - 1) / 2)
                .allowsHitTesting(!model.clearingLibraryData)
            }
        }
        .background(Palette.background)
        .tint(Palette.accent)
        .foregroundStyle(Palette.foreground)
        .frame(minWidth: 1020, minHeight: 700)
        .disabled(model.clearingLibraryData)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                    Text(notice).consoleFont(12)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { model.notice = nil } label: {
                        Image(systemName: "xmark").consoleFont(10, weight: .medium)
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted)
                    .help(L("关闭提示")).accessibilityLabel(L("关闭提示"))
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1) }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24).padding(.top, 36)
                .transition(.opacity)
                .accessibilityIdentifier("console-toast")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: model.notice != nil)
        .sheet(item: Binding<BatchExportMode?>(get: {
            if case .processing = model.imageProcessingRoute { return nil }
            return model.batchExportMode
        }, set: { mode in
            guard model.imageProcessingRoute == nil else { return }
            if mode == nil { model.dismissImageExport() }
            else { model.batchExportMode = mode }
        })) { mode in
            BatchExportView(model: model, mode: mode)
                .environment(\.consoleFontScale, 1)
                .font(.system(size: 13))
        }
        .alert(L("重命名"), isPresented: Binding(get: { model.renameItem != nil }, set: { if !$0 { model.renameItem = nil } })) {
            TextField(L("文件名"), text: $model.renameText).environment(\.isFocusEffectEnabled, true)
            Button(L("取消"), role: .cancel) { model.renameItem = nil }
            Button(L("保存")) { model.rename() }
        } message: { Text(L("保留原文件扩展名。")) }
        .consoleTypography()
        .onReceive(model.recorder.$isRecording.removeDuplicates()) { isRecording = $0 }
        // Editable fields restore isFocusEffectEnabled directly; a nested focusEffectDisabled(false) cannot override this scope.
        .focusEffectDisabled()
    }

    private var sidebar: some View {
        let scale = max(1, appearance.consoleFontSize.scale)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: ClipatoBrand.mark).resizable().renderingMode(.template)
                    .frame(width: 18 * scale, height: 18 * scale)
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 30 * scale, height: 30 * scale)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text("Clipato").consoleFont(14, weight: .semibold).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 56 * scale).padding(.top, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarGroupTitle(L("资料库"))
                    ForEach([LibrarySection.images, .recordings], id: \.self) { section in
                        navigationRow(section)
                    }
                    sidebarGroupTitle(L("工具")).padding(.top, 14)
                    navigationRow(.imageProcessing)
                    if let library = model.library {
                        CollectionSidebarView(model: model, library: library).padding(.top, 16)
                    }
                }
                .padding(.top, 6).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Palette.line).frame(height: 1)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                ForEach([LibrarySection.appearance, .general, .security, .aiTerminal, .shortcuts, .guide], id: \.self) { section in
                    navigationRow(section)
                }
                if let library = model.library {
                    StorageUsageView(library: library).padding(.top, 8)
                }
            }
            .padding(.top, 8).padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .background(Palette.sidebar)
    }

    private func sidebarGroupTitle(_ title: String) -> some View {
        Text(title).consoleFont(10, weight: .semibold)
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func navigationRow(_ section: LibrarySection) -> some View {
        let isSelected = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon).consoleFont(14, weight: .medium)
                    .frame(width: 20 * appearance.consoleFontSize.scale)
                    .foregroundStyle(isSelected ? Palette.onAccent : Palette.muted)
                Text(section.title).consoleFont(12, weight: isSelected ? .semibold : .medium)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if section == .images, let library = model.library {
                    ImageCount(library: library, isSelected: isSelected)
                }
            }
            .padding(.leading, 10).padding(.trailing, 6)
            .frame(height: 36 * max(1, appearance.consoleFontSize.scale))
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarItemStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(section.title)
        .padding(.bottom, 3)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.section == .imageProcessing, let route = model.imageProcessingRoute {
                Button(L("图像处理")) { model.dismissImageProcessing() }
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("image-processing-root")
                Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                switch route {
                case .sourceSelection(let capability):
                    Text(capability.title).foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("选择来源")).consoleFont(14, weight: .semibold)
                case .toolSelection(let tool):
                    Button(tool.title) { model.selectImageProcessingSource(.tool(tool)) }
                        .foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("截图保管箱")).consoleFont(14, weight: .semibold)
                case .processing(let tool):
                    Button(tool.title) { model.selectImageProcessingSource(.tool(tool)) }
                        .foregroundStyle(Palette.muted)
                    if let source = model.imageProcessingSource {
                        Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                        Button(source.title, action: model.returnToImageProcessingInput)
                            .foregroundStyle(Palette.muted)
                    }
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("参数设置")).consoleFont(14, weight: .semibold)
                case .renameSelection:
                    Button(L("批量命名")) { model.selectImageProcessingSource(.rename) }
                        .foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("截图保管箱")).consoleFont(14, weight: .semibold)
                case .renamePreview:
                    Button(L("批量命名")) { model.selectImageProcessingSource(.rename) }
                        .foregroundStyle(Palette.muted)
                    if !model.batchRenameAssets.contains(where: { if case .video = $0 { return true }; return false }),
                       let source = model.imageProcessingSource {
                        Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                        Button(source.title, action: model.returnToImageProcessingInput)
                            .foregroundStyle(Palette.muted)
                    }
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("命名预览")).consoleFont(14, weight: .semibold)
                case .scanResults:
                    Button(model.scanMode.title) { model.selectImageProcessingSource(.scan(model.scanMode)) }
                        .foregroundStyle(Palette.muted)
                    if let source = model.imageProcessingSource {
                        Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                        Button(source.title, action: model.returnToImageProcessingInput)
                            .foregroundStyle(Palette.muted)
                            .accessibilityIdentifier("asset-scan-input")
                    }
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("检测结果")).consoleFont(14, weight: .semibold)
                case .scanSelection:
                    Button(model.scanMode.title) { model.selectImageProcessingSource(.scan(model.scanMode)) }
                        .foregroundStyle(Palette.muted)
                    Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                    Text(L("截图保管箱")).consoleFont(14, weight: .semibold)
                }
            } else if model.section == .collections, let library = model.library {
                CollectionTitle(library: library, id: model.selectedCollectionID)
                    .consoleFont(17, weight: .semibold).lineLimit(1)
            } else {
                Text(model.section.title).consoleFont(17, weight: .semibold)
            }
            Spacer()
            if model.section == .images {
                Button { model.importImages() } label: { Label(L("导入图片"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(QuietButtonStyle()).fixedSize()
                Button { model.capture(region: true) } label: { Label(model.capturing ? L("正在截图…") : L("截取区域"), systemImage: "viewfinder") }
                    .buttonStyle(AccentButtonStyle()).disabled(model.capturing || model.library == nil).fixedSize()
            } else if model.section == .recordings {
                Button { model.section = .general } label: { Image(systemName: "gearshape") }
                    .buttonStyle(QuietButtonStyle()).help(L("系统设置"))
                    .accessibilityLabel(L("系统设置"))
                Button { model.toggleRecording() } label: {
                    Label(model.selectingRecordingRegion ? L("正在框选…") : model.recordingBusy ? L("处理中…") : isRecording ? L("停止并保存") : L("开始录屏"),
                          systemImage: isRecording ? "stop.fill" : "record.circle")
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(model.recordingBusy || model.library == nil || model.fixedCaptureRegion != nil || (!isRecording && model.capturing))
                .fixedSize()
                .help(L("录屏不支持录音，主要用于后续按帧截取图片。"))
            }
        }
        .buttonStyle(.plain).consoleFont(12)
        .disabled(model.section == .imageProcessing && model.imageProcessingNavigationBlocked)
        .padding(.horizontal, 24).frame(height: 56 * max(1, appearance.consoleFontSize.scale))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

private struct CollectionTitle: View {
    @ObservedObject var library: LibraryStore
    let id: UUID?

    var body: some View {
        Text(library.collections.first { $0.id == id }?.name ?? L("收藏夹"))
    }
}

private struct ImageCount: View {
    @ObservedObject var library: LibraryStore
    let isSelected: Bool
    var body: some View {
        SidebarCount(count: library.images.count, isSelected: isSelected)
    }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.consoleFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.consoleFont(12, weight: .medium)
            .labelStyle(CenteredIconLabelStyle())
            .foregroundStyle(Palette.onAccent)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .frame(minHeight: 28 * max(1, fontScale))
            .background(Palette.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.consoleFontScale) private var fontScale

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.consoleFont(12, weight: .medium)
            .labelStyle(CenteredIconLabelStyle())
            .foregroundStyle((configuration.role == .destructive ? Color.red : Palette.foreground)
                .opacity(configuration.isPressed ? 0.6 : 0.85))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minHeight: 28 * max(1, fontScale))
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay { SurfaceBorder(cornerRadius: 6) }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

