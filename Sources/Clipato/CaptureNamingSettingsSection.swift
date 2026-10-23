import SwiftUI

struct CaptureNamingSettingsSection: View {
    private let defaults: UserDefaults
    @State private var screenshot: String
    @State private var recording: String
    @State private var indices: (screenshot: Int, recording: Int)?
    @State private var previewDate = Date()
    @State private var screenshotPreview: String?
    @State private var recordingPreview: String?
    @State private var error: String?
    @State private var saved = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _screenshot = State(initialValue: defaults.string(forKey: CaptureNamingKind.screenshot.templateKey)
                            ?? CaptureNamingKind.screenshot.defaultTemplate)
        _recording = State(initialValue: defaults.string(forKey: CaptureNamingKind.recording.templateKey)
                           ?? CaptureNamingKind.recording.defaultTemplate)
    }

    private var hasChanges: Bool {
        screenshot != (defaults.string(forKey: CaptureNamingKind.screenshot.templateKey) ?? CaptureNamingKind.screenshot.defaultTemplate)
            || recording != (defaults.string(forKey: CaptureNamingKind.recording.templateKey) ?? CaptureNamingKind.recording.defaultTemplate)
    }

    var body: some View {
        Section(L("自动命名")) {
            ruleField(L("截图规则"), text: $screenshot, preview: screenshotPreview, identifier: "screenshot-naming-rule")
            ruleField(L("录屏规则"), text: $recording, preview: recordingPreview, identifier: "recording-naming-rule")
            VStack(alignment: .leading, spacing: 5) {
                Text(L("支持固定文字、{date} 日期、{time} 时间、{index} 编号；{index:4} 表示至少补齐 4 位（1–12 位）。请勿填写扩展名。"))
                Text(L("日期格式 yyyy-MM-dd，时间格式 HH.mm.ss。编号默认至少 3 位，超出位数时自动扩展；截图与录屏分别连续编号，重启后接续。预览不占用编号，取消或失败可能跳号。"))
                Text(L("保存后仅用于新截图和新录屏；导入、已有文件及命令行或 MCP 指定的输出不受影响。"))
            }
            .consoleFont(11).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if hasChanges {
                    Text(L("更改尚未保存")).consoleFont(11).foregroundStyle(Palette.muted)
                } else if saved {
                    Text(L("命名规则已保存")).consoleFont(11).foregroundStyle(Palette.accent)
                }
                Spacer(minLength: 0)
                Button(L("保存设置"), action: save)
                    .disabled(!hasChanges || error != nil)
                    .accessibilityIdentifier("save-capture-naming-rules")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .consoleFont(11).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: loadPreview)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: RunLoop.main)) { _ in loadPreview() }
        .onChange(of: screenshot) { _, _ in saved = false; updatePreview() }
        .onChange(of: recording) { _, _ in saved = false; updatePreview() }
    }

    private func ruleField(_ title: String, text: Binding<String>, preview: String?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).consoleFont(12, weight: .medium)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .environment(\.isFocusEffectEnabled, true)
                .accessibilityIdentifier(identifier)
            if let preview {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("命名预览")).foregroundStyle(Palette.muted)
                    Text(preview).textSelection(.enabled)
                }
                .consoleFont(11).lineLimit(2)
                .accessibilityIdentifier(identifier + "-preview")
            }
        }
        .padding(.vertical, 3)
    }

    private func loadPreview() {
        do {
            let screenshotIndex = try CaptureFileNaming.nextIndex(for: .screenshot, defaults: defaults)
            let recordingIndex = try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults)
            indices = (screenshotIndex, recordingIndex)
            previewDate = Date()
            updatePreview()
        } catch {
            indices = nil
            screenshotPreview = nil
            recordingPreview = nil
            self.error = error.localizedDescription
        }
    }

    private func updatePreview() {
        guard let indices else { return }
        do {
            screenshotPreview = try CaptureNamingRule(template: screenshot).filename(extension: "png", date: previewDate, index: indices.screenshot)
            recordingPreview = try CaptureNamingRule(template: recording).filename(extension: "mp4", date: previewDate, index: indices.recording)
            error = nil
        } catch {
            screenshotPreview = nil
            recordingPreview = nil
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            try CaptureFileNaming.save(screenshot: screenshot, recording: recording, defaults: defaults)
            loadPreview()
            saved = error == nil
        } catch { self.error = error.localizedDescription }
    }
}
