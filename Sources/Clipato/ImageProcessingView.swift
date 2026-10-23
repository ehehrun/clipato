import SwiftUI

struct ImageProcessingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale

    private var presentingOperation: Bool {
        model.isExporting || model.batchExportMode != nil || model.scanDeletionInProgress
    }

    var body: some View {
        Group {
            switch model.imageProcessingRoute {
            case .sourceSelection(let capability):
                sourceSelection(for: capability)
            case .toolSelection(let tool):
                VaultImagePickerView(library: library, selected: $model.selected,
                                     allowsMultipleSelection: tool != .grid,
                                     onCancel: { model.selectImageProcessingSource(.tool(tool)) }) { images in
                    model.prepareImageExport(images, mode: .files, tool: tool)
                }.id(tool)
            case .processing(let tool):
                BatchExportView(model: model, mode: .files, embedded: true).id(tool)
            case .renameSelection:
                VaultImagePickerView(library: library, selected: $model.selected,
                                     allowsMultipleSelection: true, minimumSelectionCount: 2,
                                     onCancel: { model.selectImageProcessingSource(.rename) }) { images in
                    model.prepareBatchRename(images.map { .image($0.id) })
                }
            case .renamePreview:
                BatchRenameView(model: model, library: library)
                    .id(model.batchRenameAssets).id(model.externalRenameURLs)
            case .scanSelection:
                VaultImagePickerView(library: library, selected: $model.selected,
                                     allowsMultipleSelection: true, minimumSelectionCount: 2,
                                     onCancel: { model.selectImageProcessingSource(.scan(model.scanMode)) }) { images in
                    model.prepareAssetScan(images.map { .image($0.id) }, mode: model.scanMode)
                }
            case .scanResults:
                AssetScanView(model: model, library: library, mode: model.scanMode,
                              assets: model.scanAssets, externalURLs: model.externalScanURLs)
                    .id(model.scanMode).id(model.scanAssets)
            case nil:
                overview
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 300 * max(1, fontScale)), spacing: 14)]
    }

    private func sourceSelection(for capability: ImageProcessingCapability) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("选择图片来源")).consoleFont(16, weight: .semibold)
                LazyVGrid(columns: columns, spacing: 14) {
                    capabilityCard(title: L("外部图片"), symbol: "folder",
                                   detail: L("从文件选择图片，不会自动导入保管箱。")) {
                        model.chooseExternalImageProcessing(capability)
                    }
                    .accessibilityIdentifier("processing-source-files")
                    capabilityCard(title: L("截图保管箱"), symbol: "square.stack.3d.up",
                                   detail: L("搜索、筛选并选择已保存的图片。")) {
                        model.chooseVaultImageProcessing(capability)
                    }
                    .accessibilityIdentifier("processing-source-vault")
                }
                Button(L("返回图像处理"), action: model.dismissImageProcessing)
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("image-processing-source-selection")
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                LazyVGrid(columns: columns, spacing: 14) {
                    toolCard(.compress, symbol: "arrow.down.right.and.arrow.up.left",
                             detail: L("压缩到目标体积，尽量保留画质。"))
                    toolCard(.resize, symbol: "arrow.up.left.and.arrow.down.right",
                             detail: L("批量输出指定尺寸，支持裁剪和补白。"))
                    toolCard(.convert, symbol: "arrow.triangle.2.circlepath",
                             detail: L("转换 JPEG、PNG 和 WebP 格式。"))
                    toolCard(.grid, symbol: "square.grid.3x3",
                             detail: L("先裁切正方形，再切为 4 或 9 宫格。"))
                    capabilityCard(title: L("批量命名"), symbol: "textformat.123",
                                   detail: L("按顺序添加前缀和递增编号。"),
                                   action: model.selectBatchRename)
                        .disabled(model.recordingBusy)
                        .accessibilityIdentifier("processing-rename-entry")
                }
                organization
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("image-processing-overview")
    }

    private func toolCard(_ tool: ImageTool, symbol: String, detail: String) -> some View {
        capabilityCard(title: tool.title, symbol: symbol, detail: detail) {
            model.selectImageProcessing(tool)
        }
        .accessibilityIdentifier("processing-\(tool.id)-entry")
    }

    private var organization: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("重复与相似检测")).consoleFont(14, weight: .semibold)
            LazyVGrid(columns: columns, spacing: 14) {
                capabilityCard(title: L("查找重复文件"), symbol: "square.on.square",
                               detail: L("比较文件内容，找出完全相同的图片。")) {
                    model.selectAssetScan(.duplicates)
                }
                .accessibilityIdentifier("scan-duplicates-entry")
                capabilityCard(title: L("查找相似图片"), symbol: "photo.on.rectangle.angled",
                               detail: L("识别画质差异、局部包含等相似内容。")) {
                    model.selectAssetScan(.similarImages)
                }
                .accessibilityIdentifier("scan-similar-entry")
            }
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                Text(L("重复与相似检测不会自动删除图片。"))
            }
            .consoleFont(11).foregroundStyle(Palette.muted).padding(.horizontal, 2)
        }
    }

    private func capabilityCard(title: String, symbol: String, detail: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol).consoleFont(18, weight: .medium).foregroundStyle(Palette.accent)
                    .frame(width: 40 * max(1, fontScale), height: 40 * max(1, fontScale))
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).consoleFont(13, weight: .semibold)
                    Text(detail).consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 3)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").consoleFont(10, weight: .semibold)
                    .foregroundStyle(Palette.muted).frame(height: 40 * max(1, fontScale))
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(ProcessingCardStyle()).disabled(presentingOperation)
    }
}

private struct ProcessingCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Palette.card)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Palette.accent.opacity(isHovered && isEnabled ? 0.05 : 0))
                    }
            }
            .overlay {
                SurfaceBorder(color: isHovered && isEnabled ? Palette.accent.opacity(0.4) : Palette.line,
                              cornerRadius: 12, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isEnabled ? configuration.isPressed ? 0.75 : 1 : 0.45)
            .onHover { isHovered = $0 }
    }
}
