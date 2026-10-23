import AppKit
import SwiftUI

struct StorageSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section(L("文件保存位置")) {
            if let library = model.library {
                StorageDirectoryRows(model: model, library: library, recorder: model.recorder)
            } else {
                Text(L("保管箱不可用，请先处理读取错误。"))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

private struct StorageDirectoryRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: LibraryStore
    let recorder: KeyframeRecorder
    @State private var isRecording = false
    @State private var screenshotStatus: String?
    @State private var recordingStatus: String?

    private var busy: Bool {
        model.capturing || model.fixedCaptureRegion != nil || model.recordingBusy || isRecording || model.isExporting
    }

    var body: some View {
        directoryRow(L("截图与图片"), directory: library.screenshotDirectory,
                     customized: library.storage.screenshotDirectory != nil,
                     kind: .screenshots, status: screenshotStatus)
        directoryRow(L("录屏"), directory: library.recordingDirectory,
                     customized: library.storage.recordingDirectory != nil,
                     kind: .recordings, status: recordingStatus)
        Text(L("新位置用于后续截图、标注、拼图及导入图片，或后续视频与关键帧录制。已有文件保留原位，仍可在保管箱访问。"))
            .consoleFont(11).foregroundStyle(Palette.muted)
        if busy {
            Text(L("截图、录屏或导出完成后可修改保存位置。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
        }
        ForEach(library.storageAuthorizationErrors.keys.sorted(by: { $0.path < $1.path }), id: \.self) { directory in
            HStack(alignment: .top, spacing: 8) {
                Label(library.storageAuthorizationErrors[directory]!, systemImage: "exclamationmark.triangle.fill")
                    .consoleFont(11).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("重新授权…")) { authorize(directory) }.disabled(busy)
            }
        }
        ForEach(library.recordingReadErrors, id: \.self) { error in
            Label(error, systemImage: "exclamationmark.triangle")
                .consoleFont(11).foregroundStyle(.orange)
        }
        LabeledContent(L("保管箱索引")) {
            Button(L("在 Finder 中打开")) { NSWorkspace.shared.open(model.libraryRoot) }
        }
        .onReceive(recorder.$isRecording.removeDuplicates()) { isRecording = $0 }
    }

    private func directoryRow(_ title: String, directory: URL, customized: Bool,
                              kind: StorageKind, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                Button(L("选择…")) { chooseDirectory(kind, current: directory) }.disabled(busy)
                Button(L("恢复默认")) { updateDirectory(nil, kind: kind) }.disabled(busy || !customized)
            }
            Text(directory.path).consoleFont(11, design: .monospaced)
                .foregroundStyle(Palette.muted).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(L("在 Finder 中打开")) { NSWorkspace.shared.open(directory) }
                Button(L("检查访问权限")) { validate(kind) }.disabled(busy)
                if let status {
                    Text(status).consoleFont(11).foregroundStyle(Palette.muted)
                }
            }
        }.padding(.vertical, 4)
    }

    private func chooseDirectory(_ kind: StorageKind, current: URL) {
        let panel = NSOpenPanel()
        panel.title = kind == .screenshots ? L("选择截图保存位置") : L("选择录屏保存位置")
        panel.message = L("确认后检查目录读取、写入和删除权限；已有文件不会移动。")
        panel.directoryURL = current
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        defer { if DistributionChannel.isAppStore { directory.stopAccessingSecurityScopedResource() } }
        updateDirectory(directory, kind: kind)
    }

    private func authorize(_ directory: URL) {
        let panel = NSOpenPanel()
        panel.title = L("重新授权保存位置")
        panel.message = L("请选择原保存文件夹，以恢复访问；此操作不会移动文件。")
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        defer { selected.stopAccessingSecurityScopedResource() }
        do {
            try library.authorizeStorageDirectory(selected, for: directory)
            try library.reloadSessions()
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func updateDirectory(_ directory: URL?, kind: StorageKind) {
        do {
            try library.setStorageDirectory(directory, for: kind)
            setStatus(L("已验证可读写"), kind: kind)
        } catch {
            setStatus(nil, kind: kind)
            model.errorMessage = error.localizedDescription
            return
        }
        if kind == .recordings {
            do { try library.reloadSessions() }
            catch { model.errorMessage = L("保存位置已更新，但录制列表刷新失败：\(error.localizedDescription)") }
        }
    }

    private func validate(_ kind: StorageKind) {
        do {
            try library.validateStorageDirectory(for: kind)
            setStatus(L("已验证可读写"), kind: kind)
        } catch {
            setStatus(nil, kind: kind)
            model.errorMessage = error.localizedDescription
        }
    }

    private func setStatus(_ value: String?, kind: StorageKind) {
        switch kind {
        case .screenshots: screenshotStatus = value
        case .recordings: recordingStatus = value
        }
    }
}
