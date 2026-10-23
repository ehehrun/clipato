import AppKit
import SwiftUI

struct AppearanceSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.consoleFontScale) private var fontScale
    private let appearance: AppearanceSettings
    private let language = LanguageSettings.shared

    init(model: AppModel, appearance: AppearanceSettings = .shared) {
        self.model = model
        self.appearance = appearance
    }

    private var isDark: Bool { colorScheme == .dark }
    private var colors: AppearanceColors { isDark ? appearance.dark : appearance.light }

    var body: some View {
        Form {
            Section(L("语言")) {
                Picker(L("显示语言"), selection: Binding(get: { language.language }, set: { language.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Text(L("立即应用于控制台和工具条。系统语言未受支持时使用英语。"))
                    .consoleFont(11).foregroundStyle(.secondary)
            }
            Section(L("外观")) {
                Picker(L("模式"), selection: $model.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L("强调色"))
                        Spacer()
                        Text(appearance.preset?.title ?? L("自定义"))
                            .consoleFont(11).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(AppearancePreset.allCases) { preset in
                            presetButton(preset)
                        }
                    }
                    .frame(maxWidth: 480 * max(1, fontScale))
                    Text(L("仅为按钮、选中项和重点操作添加颜色。"))
                        .consoleFont(11).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("控制台字体大小"))
                        Spacer()
                        Text(L("\(appearance.consoleFontSize.title) · \(appearance.consoleFontSize.rawValue) px"))
                            .consoleFont(11).foregroundStyle(.secondary)
                        Text(appearance.consoleFontSize.scale, format: .percent.precision(.fractionLength(0)))
                            .consoleFont(11, design: .monospaced).foregroundStyle(.secondary)
                    }
                    Picker(L("控制台字体大小"), selection: Binding(get: { appearance.consoleFontSize }, set: appearance.setConsoleFontSize)) {
                        ForEach(ConsoleFontSize.allCases) { size in
                            Text(L("\(size.rawValue) px")).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(L("14 px 为正常倍率；整体调整控制台字号，保留标题、正文和辅助文字的大小层级。"))
                        .consoleFont(11).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                DisclosureGroup(L("自定义配色")) {
                    colorRow(L("强调色"), field: \.accent)
                    colorRow(L("背景"), field: \.background)
                    colorRow(L("文字"), field: \.foreground)
                    Text(L("正在调整\(isDark ? L("深色") : L("浅色"))模式，配色分别保存并立即生效。"))
                        .consoleFont(11).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("自定义背景与文字可能影响可读性。"))
                        .consoleFont(11).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                HStack {
                    Spacer()
                    Button(L("恢复默认配色")) { appearance.restoreDefaults() }
                        .disabled(appearance.preset == .oat)
                }
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(FullRowDisclosureGroupStyle())
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(Color(nsColor: .labelColor))
        .tint(Color(nsColor: .controlAccentColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .consoleTypography()
        .focusEffectDisabled()
    }

    private func presetButton(_ preset: AppearancePreset) -> some View {
        let colors = isDark ? preset.dark : preset.light
        let accent = Color(nsColor: AppearanceColors.color(colors.accent))
        let onAccent = Color(nsColor: AppearancePalette.contrastingText(for: AppearanceColors.color(colors.accent)))
        let selected = appearance.preset == preset
        return Button { appearance.apply(preset) } label: {
            VStack(spacing: 7) {
                Circle().fill(accent)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark")
                                .consoleFont(12, weight: .bold)
                                .foregroundStyle(onAccent)
                        }
                    }
                    .frame(width: 28 * max(1, fontScale), height: 28 * max(1, fontScale))
                    .padding(4)
                    .overlay { Circle().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1.5) }
                Text(preset.title)
                    .consoleFont(11, weight: selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .environment(\.isFocusEffectEnabled, true)
        .help(preset.title)
        .accessibilityLabel(preset.title)
        .accessibilityIdentifier("appearance-preset-\(preset.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func colorRow(_ title: String, field: WritableKeyPath<AppearanceColors, UInt32>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Text(String(format: "#%06X", colors[keyPath: field]))
                    .consoleFont(11, design: .monospaced)
                    .textSelection(.enabled)
                WindowColorPicker(title: title, selection: Binding(get: {
                    Color(nsColor: AppearanceColors.color(colors[keyPath: field]))
                }, set: { value in
                    var updated = colors
                    updated[keyPath: field] = AppearanceColors.rgb(NSColor(value))
                    appearance.update(updated, dark: isDark)
                }))
                .fixedSize()
            }
        }
    }
}
