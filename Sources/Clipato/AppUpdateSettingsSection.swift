import AppKit
import SwiftUI

struct AppUpdateSettingsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section(L("关于与更新")) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                Text("Clipato")
                    .consoleFont(20, weight: .semibold)
            }
            .padding(.vertical, 4)
            LabeledContent(L("当前版本")) {
                Text("\(AppVersion.number) (\(AppVersion.build))")
                    .textSelection(.enabled)
                    .accessibilityIdentifier("app-version")
            }
            LabeledContent(L("作者")) {
                Text("ehehrun")
                    .textSelection(.enabled)
            }
            LabeledContent(L("意见反馈")) {
                Link("ehehrun@kodify.vip", destination: URL(string: "mailto:ehehrun@kodify.vip")!)
                    .accessibilityIdentifier("feedback-email")
            }
            if DistributionChannel.isAppStore {
                Text(L("更新由 Mac App Store 提供。"))
                    .consoleFont(11).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("app-store-update-notice")
            } else {
                HStack(spacing: 8) {
                    Button(action: model.checkForUpdates) {
                        Label(L("检查更新"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .fixedSize()
                    .disabled(model.updateCheckState == .checking)
                    .accessibilityIdentifier("check-for-updates")
                    if model.updateCheckState == .checking {
                        ProgressView().controlSize(.small)
                        Text(L("正在检查…")).consoleFont(11).foregroundStyle(Palette.muted)
                    }
                }
                switch model.updateCheckState {
                case .idle, .checking:
                    EmptyView()
                case .upToDate:
                    Label(L("当前已是最新版本"), systemImage: "checkmark.circle")
                        .consoleFont(12).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("update-result")
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .consoleFont(12).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("前往仓库"), action: model.openUpdateRepository)
                            .buttonStyle(QuietButtonStyle())
                            .accessibilityIdentifier("open-update-repository")
                    }
                    .accessibilityIdentifier("update-result")
                case .available(let release):
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("发现新版本 \(release.name)"), systemImage: "arrow.down.circle")
                            .consoleFont(13, weight: .semibold)
                        Button(L("前往下载")) {
                            let url = AppUpdateChecker.releasesURL
                            if !NSWorkspace.shared.open(url) {
                                model.errorMessage = L("无法打开下载地址：\(url.absoluteString)")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("open-update-download")
                    }
                    .accessibilityIdentifier("update-result")
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
