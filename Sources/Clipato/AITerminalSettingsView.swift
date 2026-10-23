import AppKit
import SwiftUI

struct AITerminalSettingsView: View {
    @ObservedObject var model: AppModel
    private let accessLog: MCPAccessLog
    @State private var showingLogs = false
    @State private var logError: String?
    @Environment(\.consoleFontScale) private var fontScale
    @State private var maximumMB: String
    @State private var savedMaximumMB: Int
    @State private var savingLimit = false
    @State private var capacitySaved = false

    init(model: AppModel, accessLog: MCPAccessLog = .shared, defaults: UserDefaults = .standard) {
        self.model = model
        self.accessLog = accessLog
        let maximumMB = MCPAccessLog.maximumMB(in: defaults)
        _maximumMB = State(initialValue: String(maximumMB))
        _savedMaximumMB = State(initialValue: maximumMB)
    }

    private var parsedMaximumMB: Int? {
        guard let value = Int(maximumMB.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...1024).contains(value) else { return nil }
        return value
    }

    var body: some View {
        Group {
            if showingLogs {
                MCPAccessLogView { showingLogs = false }
            } else {
                Form {
                    if DistributionChannel.isAppStore {
                        Section(L("自动化接入")) {
                            Text(L("Mac App Store 版本不提供 CLI、MCP 或 Skills 接入。"))
                                .consoleFont(12).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("app-store-automation-unavailable")
                        }
                    } else {
                        MCPSettingsSection(privacyMode: model.privacyMode)
                        SkillSettingsSection()
                        Section(L("访问日志")) {
                            Text(L("记录 MCP 与 CLI 调用的原始参数、执行结果和耗时。进程信息由系统读取，MCP 客户端信息由客户端自报；不读取图片文件内容，不记录完整返回内容。"))
                                .consoleFont(11).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Text(L("日志总容量上限"))
                                Spacer()
                                TextField("", text: $maximumMB, onEditingChanged: { editing in
                                    if editing { capacitySaved = false }
                                })
                                    .environment(\.isFocusEffectEnabled, true)
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                                    .frame(width: 90 * max(1, fontScale))
                                    .disabled(savingLimit)
                                    .accessibilityLabel(L("日志总容量上限"))
                                    .accessibilityIdentifier("mcp-log-maximum-mb")
                                Text("MB").foregroundStyle(Palette.muted)
                                Button(L("保存设置"), action: saveLogCapacity)
                                    .buttonStyle(.bordered)
                                    .disabled(parsedMaximumMB == nil || parsedMaximumMB == savedMaximumMB || savingLimit)
                                    .accessibilityIdentifier("mcp-save-log-capacity")
                            }
                            Text(L("包含当前日志与轮转文件，超出上限后自动删除最旧日志文件。1 MB = 100 万字节。"))
                                .consoleFont(11).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            if parsedMaximumMB == nil {
                                Text(L("日志容量须为 1–1024 MB 的整数。"))
                                    .consoleFont(11).foregroundStyle(.orange)
                            } else if parsedMaximumMB != savedMaximumMB {
                                Text(L("更改尚未保存")).consoleFont(11).foregroundStyle(Palette.muted)
                            } else if capacitySaved {
                                Text(L("日志容量已保存")).consoleFont(11).foregroundStyle(Palette.accent)
                            }
                            HStack(spacing: 12) {
                                Button { showingLogs = true } label: {
                                    Label(L("查看日志"), systemImage: "doc.text.magnifyingglass")
                                }
                                .accessibilityIdentifier("mcp-view-access-log")
                                .fixedSize()
                                Button(action: MCPAccessLog.copyTailCommand) {
                                    Label(L("复制 tail -F 命令"), systemImage: "terminal")
                                }
                                .fixedSize()
                            }
                            .buttonStyle(QuietButtonStyle())
                            Text(MCPAccessLog.fileURL.path)
                                .consoleFont(11, design: .monospaced).foregroundStyle(Palette.muted)
                                .textSelection(.enabled)
                            if let logError {
                                Text(logError).consoleFont(11).foregroundStyle(.red)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Palette.background)
        .foregroundStyle(Palette.foreground)
        .tint(Palette.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .consoleTypography()
        .focusEffectDisabled()
        .task {
            guard !DistributionChannel.isAppStore else { return }
            do { try await accessLog.prepare() }
            catch { logError = error.localizedDescription }
        }
        .onChange(of: maximumMB) { _, _ in capacitySaved = false }
    }

    private func saveLogCapacity() {
        guard let value = parsedMaximumMB, value != savedMaximumMB, !savingLimit else { return }
        capacitySaved = false
        savingLimit = true
        Task {
            defer { savingLimit = false }
            do {
                try await accessLog.setMaximumMB(value)
                savedMaximumMB = value
                capacitySaved = true
                logError = nil
                await model.library?.refreshStorageUsage(enforceQuota: false)
            } catch {
                logError = error.localizedDescription
            }
        }
    }
}

private struct MCPAccessLogView: View {
    let onBack: () -> Void
    @State private var text = ""
    @State private var following = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button(L("AI 终端"), action: onBack).buttonStyle(.plain).foregroundStyle(Palette.muted)
                Image(systemName: "chevron.right").consoleFont(10).foregroundStyle(Palette.muted)
                Text(L("访问日志")).consoleFont(13, weight: .semibold)
                Spacer()
                Toggle(L("实时更新"), isOn: $following).toggleStyle(.checkbox)
                Button(L("复制 tail -F 命令"), action: MCPAccessLog.copyTailCommand)
                    .buttonStyle(.bordered)
            }
            .consoleFont(12)
            Text(MCPAccessLog.fileURL.path).consoleFont(10, design: .monospaced)
                .foregroundStyle(Palette.muted).textSelection(.enabled)
            if let errorMessage {
                Text(errorMessage).consoleFont(12).foregroundStyle(.red)
            }
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty && errorMessage == nil ? L("暂无访问日志。") : text)
                            .consoleFont(11, design: .monospaced).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("log-end")
                    }
                    .padding(12)
                }
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay { SurfaceBorder(color: Palette.line, cornerRadius: 8) }
                .onChange(of: text) { _, _ in
                    if following { proxy.scrollTo("log-end", anchor: .bottom) }
                }
            }
            Text(L("显示当前文件最近 256 KB；tail -F 可持续跟踪轮转后的日志。旧日志保存在同一目录。"))
                .consoleFont(10).foregroundStyle(Palette.muted)
        }
        .padding(20)
        .task(id: following) {
            do {
                repeat {
                    text = try await MCPAccessLog.shared.recentText()
                    errorMessage = nil
                    if !following { return }
                    try await Task.sleep(for: .seconds(1))
                } while !Task.isCancelled
            } catch is CancellationError {
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
