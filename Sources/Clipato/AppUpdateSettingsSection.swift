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
                    Label(message, systemImage: "exclamationmark.triangle")
                        .consoleFont(12).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("update-result")
                case .available(let release):
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L("发现新版本 \(release.version)（构建 \(release.build)）"), systemImage: "arrow.down.circle")
                            .consoleFont(13, weight: .semibold)
                        Text(release.releaseNotes)
                            .consoleFont(12).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("前往下载")) {
                            if !NSWorkspace.shared.open(release.downloadURL) {
                                model.errorMessage = L("无法打开下载地址：\(release.downloadURL.absoluteString)")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("open-update-download")
                    }
                    .accessibilityIdentifier("update-result")
                    .padding(.vertical, 4)
                }
                if let cachedAt = model.updateCheckCachedAt {
                    let date = cachedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                        .locale(LanguageSettings.shared.locale))
                    Text(L("今日更新请求已达 5 次，显示上次成功检查的结果（\(date)）。"))
                        .consoleFont(11).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("update-cache-notice")
                }
            }
        }
    }
}
