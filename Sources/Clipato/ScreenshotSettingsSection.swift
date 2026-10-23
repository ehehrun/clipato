import SwiftUI

struct ScreenshotSettingsSection: View {
    @AppStorage("screenshotShowsFullScreenCrosshair") private var showsFullScreenCrosshair = true
    @AppStorage(ScreenshotColorFormat.defaultsKey) private var colorFormat = ScreenshotColorFormat.hex

    var body: some View {
        Section(L("截图与取色")) {
            Toggle(L("显示全屏十字线"), isOn: $showsFullScreenCrosshair)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("screenshot-fullscreen-crosshair")
            Picker(L("默认色值格式"), selection: $colorFormat) {
                ForEach(ScreenshotColorFormat.allCases, id: \.self) { format in
                    Text(format.title).tag(format)
                }
            }
            .accessibilityIdentifier("screenshot-color-format")
            Text(L("框选前，鼠标旁显示像素放大镜和色值。C 复制色值，Tab 切换格式；开始框选后隐藏取色信息。"))
                .consoleFont(11).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
