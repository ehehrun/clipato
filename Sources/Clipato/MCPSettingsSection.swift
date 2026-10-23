import SwiftUI
import AppKit

struct MCPSettingsSection: View {
    let privacyMode: Bool
    @AppStorage(MCPSettings.enabledKey) private var enabled = false
    @AppStorage(MCPSettings.serverEnabledKey) private var serverEnabled = false
    @AppStorage(MCPSettings.allowTrashKey) private var allowTrash = false
    @State private var errorMessage: String?
    @State private var confirmingAutomationAccess = false

    var body: some View {
        Group {
            Section(L("自动化接入")) {
                Toggle(L("允许外部自动化调用"), isOn: Binding(get: { enabled && !privacyMode }, set: { MCPSettings.setEnabled($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(privacyMode)
                    .accessibilityIdentifier("mcp-enabled")
                if privacyMode {
                    Label(L("隐私模式已开启，无法启用外部调用。"), systemImage: "lock.fill")
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
                Text(L("允许 Skills、MCP 和命令行执行操作。关闭总开关会同时关闭 MCP，取消所有正在进行的外部任务；已完成的写入不会撤回。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled && !privacyMode {
                    Toggle(L("允许自动化请求移入废纸篓"), isOn: $allowTrash)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("mcp-allow-trash")
                    Text(L("默认禁止。开启后，每批操作仍需在 Clipato 确认；不提供永久删除或清空全部数据。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("MCP 服务")) {
                Toggle(L("启用 MCP 服务"), isOn: Binding(
                    get: { serverEnabled && enabled && !privacyMode },
                    set: { requested in
                        if requested && !enabled {
                            confirmingAutomationAccess = true
                        } else {
                            MCPSettings.setServerEnabled(requested)
                        }
                    }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(privacyMode)
                    .accessibilityIdentifier("mcp-server-enabled")
                    .alert(L("允许外部调用并启用 MCP？"), isPresented: $confirmingAutomationAccess) {
                        Button(L("取消"), role: .cancel) {}
                        Button(L("允许并启用")) {
                            MCPSettings.setEnabled(true)
                            MCPSettings.setServerEnabled(true)
                        }
                    } message: {
                        Text(L("启用 MCP 需要允许外部自动化调用。确认后，Skills、MCP 和命令行将可执行截图、录屏、保管箱和图像处理操作。移入废纸篓仍需单独授权。"))
                    }
                Text(L("默认关闭。仅影响 MCP 客户端；关闭会断开会话并取消 MCP 任务，Skills 与命令行仍可使用。重新开启后，客户端需重新连接。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if !enabled && !privacyMode {
                    Text(L("点击启用时，将先确认外部自动化调用权限。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                }
                if serverEnabled && enabled && !privacyMode {
                    Text(L("在 MCP 客户端中添加以下命令，参数为 mcp。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                    Text(Bundle.main.executableURL!.path)
                        .consoleFont(11, design: .monospaced)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        do {
                            let configuration = try MCPSettings.configuration(executable: Bundle.main.executableURL!)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(configuration, forType: .string)
                        } catch { errorMessage = error.localizedDescription }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                            Text(L("复制 MCP 配置"))
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                    if let errorMessage {
                        Text(errorMessage).consoleFont(11).foregroundStyle(.red)
                    }
                }
            }
        }
        .onChange(of: allowTrash) { _, _ in UserDefaults.standard.synchronize() }
        .onChange(of: privacyMode) { _, privacyMode in
            if privacyMode { confirmingAutomationAccess = false }
        }
    }
}
