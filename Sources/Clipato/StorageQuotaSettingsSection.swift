import SwiftUI

struct StorageQuotaSettingsSection: View {
    @ObservedObject var library: LibraryStore
    @Environment(\.consoleFontScale) private var fontScale
    @State private var limitEnabled: Bool
    @State private var limitGB: String
    @State private var automaticallyRemoveOldestImages: Bool
    @State private var protectTaggedImages: Bool
    @State private var protectCollectedImages: Bool
    @State private var keepRecentImages: Bool
    @State private var saveError: String?
    @State private var saved = false

    init(library: LibraryStore) {
        self.library = library
        let policy = library.storagePolicy
        _limitEnabled = State(initialValue: policy.maximumBytes != nil)
        _limitGB = State(initialValue: policy.maximumBytes.map { String(Double($0) / 1_000_000_000) } ?? "10")
        _automaticallyRemoveOldestImages = State(initialValue: policy.automaticallyRemoveOldestImages)
        _protectTaggedImages = State(initialValue: policy.protectTaggedImages)
        _protectCollectedImages = State(initialValue: policy.protectCollectedImages)
        _keepRecentImages = State(initialValue: policy.keepRecentDays > 0)
    }

    private var maximumBytes: Int64? {
        guard let value = Double(limitGB.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        let bytes = value * 1_000_000_000
        guard bytes >= 1, bytes < Double(Int64.max) else { return nil }
        return Int64(bytes.rounded(.down))
    }

    private var hasChanges: Bool {
        let policy = library.storagePolicy
        return (limitEnabled ? maximumBytes : nil) != policy.maximumBytes
            || automaticallyRemoveOldestImages != policy.automaticallyRemoveOldestImages
            || protectTaggedImages != policy.protectTaggedImages
            || protectCollectedImages != policy.protectCollectedImages
            || (keepRecentImages ? 7 : 0) != policy.keepRecentDays
    }

    var body: some View {
        Section(L("容量管理")) {
            Toggle(L("启用媒体容量上限"), isOn: $limitEnabled)
                .toggleStyle(.checkbox)
            if limitEnabled {
                HStack {
                    Text(L("图片与录屏共用"))
                    Spacer()
                    TextField("10", text: $limitGB)
                        .environment(\.isFocusEffectEnabled, true)
                        .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
                        .frame(width: 100 * max(1, fontScale))
                        .accessibilityLabel(L("媒体容量上限，单位 GB"))
                    Text("GB").foregroundStyle(Palette.muted)
                }
                if maximumBytes == nil {
                    Text(L("请输入有效的正数容量。"))
                        .consoleFont(11).foregroundStyle(.orange)
                }
            }
            Toggle(L("自动将最早的图片移到废纸篓"), isOn: $automaticallyRemoveOldestImages)
                .toggleStyle(.checkbox).disabled(!limitEnabled)
            Toggle(L("保护有颜色标签的图片"), isOn: $protectTaggedImages)
                .toggleStyle(.checkbox)
                .disabled(!limitEnabled || !automaticallyRemoveOldestImages)
            Toggle(L("保护已加入收藏夹的图片"), isOn: $protectCollectedImages)
                .toggleStyle(.checkbox)
                .disabled(!limitEnabled || !automaticallyRemoveOldestImages)
            Toggle(L("保留最近 7 天的图片"), isOn: $keepRecentImages)
                .toggleStyle(.checkbox)
                .disabled(!limitEnabled || !automaticallyRemoveOldestImages)
            Text(L("设置保存后生效。图片与录屏共用媒体容量上限；缓存、访问日志、索引及设置单独统计，不计入上限。1 GB = 10 亿字节。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
            Text(L("超限时，自动清理只处理符合条件的最早图片，不删除录屏或本次新图。收藏图片默认保留；关闭收藏保护后才参与清理。移除的图片可从废纸篓恢复，清空废纸篓后才会释放磁盘空间。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
            HStack {
                if hasChanges {
                    Text(L("更改尚未保存")).consoleFont(11).foregroundStyle(Palette.muted)
                } else if saved {
                    Text(L("容量设置已保存")).consoleFont(11).foregroundStyle(Palette.accent)
                }
                Spacer()
                Button(L("保存设置"), action: save)
                    .disabled(!hasChanges || (limitEnabled && maximumBytes == nil))
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .consoleFont(11).foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        var policy = library.storagePolicy
        policy.maximumBytes = limitEnabled ? maximumBytes : nil
        policy.automaticallyRemoveOldestImages = automaticallyRemoveOldestImages
        policy.protectTaggedImages = protectTaggedImages
        policy.protectCollectedImages = protectCollectedImages
        policy.keepRecentDays = keepRecentImages ? 7 : 0
        do {
            try library.updateStoragePolicy(policy)
            saveError = nil
            saved = true
        } catch {
            saveError = error.localizedDescription
            saved = false
        }
    }
}
