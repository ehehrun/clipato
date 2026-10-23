import SwiftUI

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmClearLibraryData = false

    var body: some View {
        Form {
            AppUpdateSettingsSection(model: model)
            ScreenshotSettingsSection()
            CaptureNamingSettingsSection()
            RecordingSettingsSection(model: model)
            StorageSettingsSection(model: model)
            if let library = model.library {
                StorageQuotaSettingsSection(library: library)
            }
            Section(L("数据清理")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(L("选择要清理的图片、录屏、收藏夹和操作历史。"))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .consoleFont(11)
                    Button(role: .destructive) { confirmClearLibraryData = true } label: {
                        HStack(spacing: 8) {
                            if model.clearingLibraryData { ProgressView().controlSize(.small) }
                            Label(model.clearingLibraryData ? L("正在清理…") : L("清理数据…"), systemImage: "trash")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                    .disabled(!model.canClearLibraryData)
                    .accessibilityIdentifier("clear-library-data")
                    if model.library != nil, !model.canClearLibraryData, !model.clearingLibraryData {
                        Text(L("请先完成当前截图、录屏、编辑或图像处理操作。"))
                            .consoleFont(11).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .tint(Palette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .consoleTypography()
        .focusEffectDisabled()
        .sheet(isPresented: $confirmClearLibraryData) {
            LibraryCleanupConfirmationView(model: model, onCancel: {
                confirmClearLibraryData = false
            }, onConfirm: { options in
                confirmClearLibraryData = false
                model.clearLibraryData(options: options)
            })
            .consoleTypography()
        }
    }
}

struct LibraryCleanupConfirmationView: View {
    @ObservedObject var model: AppModel
    let onCancel: () -> Void
    let onConfirm: (LibraryCleanupOptions) -> Void
    @Environment(\.consoleFontScale) private var fontScale
    @State private var options = LibraryCleanupOptions()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "trash.fill")
                    .consoleFont(24).foregroundStyle(.red)
                    .frame(width: 40 * fontScale, height: 40 * fontScale)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("清理数据"))
                        .consoleFont(18, weight: .semibold)
                    Text(L("请选择要清理的数据。此操作无法在应用内撤销。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 18) {
                cleanupOption(L("保管箱图片"), detail: L("图片移入系统废纸篓，同时移除对应收藏关系和最近贴图记录。"), selection: $options.images, identifier: "cleanup-images")
                cleanupOption(L("录屏"), detail: L("关键帧录屏和视频移入系统废纸篓，同时移除对应收藏关系。"), selection: $options.recordings, identifier: "cleanup-recordings")
                cleanupOption(L("收藏夹"), detail: L("删除全部收藏夹及其归类关系；仅勾选此项不会删除图片或录屏原件。"), selection: $options.collections, identifier: "cleanup-collections")
                cleanupOption(L("操作历史"), detail: L("清空最近贴图记录。"), selection: $options.history, identifier: "cleanup-history")
            }
            .toggleStyle(.checkbox)

            Text(L("移入废纸篓的文件可从系统恢复；收藏夹和操作历史删除后无法恢复。设置会保留。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Spacer()
                Button(L("取消"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cancel-library-cleanup")
                Button(L("清理所选数据"), role: .destructive) { onConfirm(options) }
                    .foregroundStyle(.red)
                    .disabled(options.isEmpty || !model.canClearLibraryData)
                    .accessibilityIdentifier("confirm-library-cleanup")
            }
            .buttonStyle(.bordered)
            .consoleFont(12, weight: .medium)
        }
        .padding(28)
        .frame(width: 560 * max(1, fontScale), alignment: .leading)
        .foregroundStyle(Palette.foreground)
        .background(Palette.background)
        .tint(Palette.accent)
        .onExitCommand(perform: onCancel)
    }

    private func cleanupOption(_ title: String, detail: String, selection: Binding<Bool>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: selection).consoleFont(12, weight: .medium)
                .accessibilityIdentifier(identifier)
            Text(detail).consoleFont(11).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)
        }
    }
}
