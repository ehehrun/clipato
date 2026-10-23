import AppKit
import SwiftUI

struct SkillSettingsSection: View {
    @State private var working = false
    @State private var installedDirectory: URL?
    @State private var errorMessage: String?

    var body: some View {
        Section("Skills") {
            if DistributionChannel.isAppStore {
                Text(L("Mac App Store 版本不支持安装或导出可执行 Skill。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("app-store-skills-unavailable")
            } else {
                Text(L("无需配置 MCP，安装 Skill 后即可通过本机客户端调用 Clipato。实际操作仍需开启外部自动化调用权限，无需启用 MCP 服务。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { installationButtons }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) { installationButtons }
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(working)
                ForEach(SkillClient.allCases, id: \.self) { client in
                    Text("\(client.title) · \(client.directory().path)")
                        .consoleFont(10, design: .monospaced).foregroundStyle(Palette.muted)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("安装后可在新对话中使用 Clipato Skill。移动 App 后，请重新安装 Skill 以更新程序路径。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let installedDirectory {
                    HStack(spacing: 8) {
                        Text(L("Skill 已保存：\(installedDirectory.path)"))
                            .consoleFont(11).foregroundStyle(Palette.accent).textSelection(.enabled)
                        Button(L("在 Finder 中显示")) {
                            NSWorkspace.shared.activateFileViewerSelecting([installedDirectory])
                        }
                        .buttonStyle(QuietButtonStyle()).fixedSize()
                    }
                }
                if let errorMessage {
                    Text(errorMessage).consoleFont(11).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder private var installationButtons: some View {
        Button { install(to: SkillClient.codex.directory()) } label: {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(L("安装到 Codex"))
            }
        }
        .accessibilityIdentifier("install-codex-skill")
        Button { install(to: SkillClient.claudeCode.directory()) } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                Text(L("安装到 Claude Code"))
            }
        }
        .accessibilityIdentifier("install-claude-skill")
        Button(action: exportSkill) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.up")
                Text(L("导出 Skill…"))
            }
        }
        .accessibilityIdentifier("export-clipato-skill")
        if working { ProgressView().controlSize(.small) }
    }

    private func exportSkill() {
        let panel = NSOpenPanel()
        panel.title = L("导出 Clipato Skill")
        panel.message = L("选择保存位置，将创建 clipato 文件夹。")
        panel.prompt = L("导出")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        install(to: parent.appendingPathComponent("clipato", isDirectory: true))
    }

    private func install(to destination: URL) {
        guard !working else { return }
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("替换已有 Skill？")
            alert.informativeText = L("将替换此文件夹中的全部内容：\(destination.path)\n其他 Skill 和客户端配置不会更改。")
            alert.addButton(withTitle: L("替换"))
            alert.addButton(withTitle: L("取消"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let executable = Bundle.main.executableURL!
        working = true
        errorMessage = nil
        installedDirectory = nil
        Task {
            defer { working = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SkillInstallation.install(to: destination, executable: executable, replaceExisting: exists)
                }.value
                installedDirectory = destination
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
