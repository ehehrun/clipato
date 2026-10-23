import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI

struct SecuritySettingsView: View {
    @ObservedObject var model: AppModel
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var screenCaptureAuthorized = CGPreflightScreenCaptureAccess()
    @State private var changingLoginItem = false
    @State private var loginItemError: String?
    @State private var activeAnimation: GuideAnimation?
    @State private var hoveredAnimation: GuideAnimation?
    @State private var applicationActive = NSApplication.shared.isActive
    @State private var showingPrivacyPolicy = false

    var body: some View {
        GeometryReader { geometry in
            Form {
                Section(L("权限")) {
                    HStack(spacing: 8) {
                        Text(L("屏幕录制")).fontWeight(.medium)
                        statusBadge(screenCaptureAuthorized ? L("已授权") : L("未授权"),
                                    symbol: screenCaptureAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                    color: screenCaptureAuthorized ? Palette.accent : .red)
                            .accessibilityIdentifier("screen-capture-permission-status")
                        Spacer(minLength: 12)
                        Button(screenCaptureAuthorized ? L("管理权限") : L("去授权")) { model.openScreenPermissions() }
                            .buttonStyle(QuietButtonStyle())
                            .fixedSize()
                            .accessibilityIdentifier("open-screen-capture-settings")
                    }
                    Text(L("截图与录屏共用此权限。Clipato 仅采集画面，不采集系统音频或麦克风。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    GuideAnimationRow(animation: .screenCapturePermission, active: $activeAnimation,
                                      hovered: $hoveredAnimation, viewport: geometry.size,
                                      applicationActive: applicationActive) {
                        VStack(alignment: .leading, spacing: 12) {
                            if !screenCaptureAuthorized {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                                    Text(L("未授权时无法截图或录屏，请在系统设置中允许 Clipato。"))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .consoleFont(11, weight: .medium).foregroundStyle(.red)
                            }
                            appDragItem(identifier: "drag-screen-capture-app")
                            Text(L("将 Clipato.app 拖入系统设置的屏幕录制列表，再打开开关；也可点击“+”添加。"))
                                .consoleFont(11).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .help(L("将鼠标移到此处播放拖拽演示。"))
                    .accessibilityIdentifier("screen-capture-permission-guide")
                    if !screenCaptureAuthorized || model.screenCapturePermissionError != nil {
                        Text(L("更改后如仍显示未授权，请完全退出 Clipato 后重新打开。"))
                            .consoleFont(11).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = model.screenCapturePermissionError {
                        DisclosureGroup(L("错误详情")) {
                            Text(error).consoleFont(11).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .accessibilityIdentifier("screen-capture-permission-error")
                    }
                }
                Section(L("启动")) {
                    HStack(spacing: 8) {
                        Toggle(L("开机启动"), isOn: Binding(get: {
                            loginItemStatus == .enabled || loginItemStatus == .requiresApproval
                        }, set: setLoginItemEnabled))
                            .toggleStyle(.checkbox)
                            // .notFound can precede the first registration; keep the explicit user action available.
                            .disabled(changingLoginItem)
                            .fixedSize()
                            .accessibilityIdentifier("launch-at-login")
                        statusBadge(loginItemStatusTitle,
                                    symbol: loginItemStatus == .enabled ? "checkmark.circle.fill"
                                        : (loginItemStatus == .requiresApproval ? "exclamationmark.circle.fill" : "minus.circle"),
                                    color: loginItemStatus == .enabled ? Palette.accent
                                        : (loginItemStatus == .requiresApproval ? Palette.warning : Palette.muted))
                            .accessibilityIdentifier("login-item-status")
                        Spacer(minLength: 0)
                    }
                    Text(L("默认关闭。开启后，登录 Mac 时自动启动 Clipato，并常驻菜单栏。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if loginItemStatus == .requiresApproval {
                        Text(L("开机启动尚未生效，请在 macOS 登录项设置中允许 Clipato。"))
                            .consoleFont(11).foregroundStyle(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let loginItemError {
                        Text(loginItemError).consoleFont(11).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("手动添加登录项")).consoleFont(12, weight: .medium)
                        Button(L("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("open-login-items-settings")
                        appDragItem(identifier: "drag-login-item-app")
                        Text(L("将 Clipato.app 拖入系统设置的“登录时打开”列表，或点击列表下方的“+”选择此应用。"))
                            .consoleFont(11).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
                Section(L("隐私")) {
                    Button(L("隐私说明")) { showingPrivacyPolicy = true }
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("open-privacy-policy")
                    Toggle(L("开启隐私模式"), isOn: $model.privacyMode)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("privacy-mode")
                    Text(L("开启后，截图不自动保存到保管箱，也不记录贴图历史。已有内容和历史不受影响。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !DistributionChannel.isAppStore {
                        Text(L("开启隐私模式会关闭 Skills、MCP 与命令行的外部调用；关闭隐私模式后需手动重新开启。"))
                            .consoleFont(11).foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .disclosureGroupStyle(FullRowDisclosureGroupStyle())
            .coordinateSpace(name: "guide-viewport")
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .foregroundStyle(Palette.foreground)
            .tint(Palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .consoleTypography()
            .focusEffectDisabled()
            .onAppear(perform: refreshPermissionStatus)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                applicationActive = true
                refreshPermissionStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                applicationActive = false
            }
        }
        .sheet(isPresented: $showingPrivacyPolicy) { PrivacyPolicyView() }
    }

    private var loginItemStatusTitle: String {
        switch loginItemStatus {
        case .enabled: return L("已开启")
        case .requiresApproval: return L("待允许")
        case .notRegistered, .notFound: return L("未开启")
        @unknown default: return L("状态未知")
        }
    }

    private func refreshPermissionStatus() {
        loginItemStatus = SMAppService.mainApp.status
        screenCaptureAuthorized = CGPreflightScreenCaptureAccess()
    }

    private func statusBadge(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(title)
        }
        .consoleFont(11, weight: .medium)
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Palette.canvas, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func appDragItem(identifier: String) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            Text("Clipato.app").consoleFont(12, weight: .medium)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line, lineWidth: 1) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
        .accessibilityLabel(L("拖动 Clipato.app"))
        .accessibilityIdentifier(identifier)
    }

    private func setLoginItemEnabled(_ enabled: Bool) {
        guard !changingLoginItem else { return }
        changingLoginItem = true
        loginItemError = nil
        Task { @MainActor in
            defer {
                loginItemStatus = SMAppService.mainApp.status
                changingLoginItem = false
            }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
            } catch {
                loginItemError = L("无法更改开机启动设置：\(error.localizedDescription)")
            }
        }
    }
}
