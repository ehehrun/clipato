import SwiftUI

private struct ConsoleFontScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var consoleFontScale: CGFloat {
        get { self[ConsoleFontScaleKey.self] }
        set { self[ConsoleFontScaleKey.self] = newValue }
    }
}

extension View {
    func consoleFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ConsoleFont(size: size, weight: weight, design: design))
    }

    func consoleTypography() -> some View {
        modifier(ConsoleTypography())
    }
}

private struct ConsoleFont: ViewModifier {
    @Environment(\.consoleFontScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

private struct ConsoleTypography: ViewModifier {
    func body(content: Content) -> some View {
        let scale = AppearanceSettings.shared.consoleFontSize.scale
        content.environment(\.consoleFontScale, scale)
            .environment(\.locale, LanguageSettings.shared.locale)
            .font(.system(size: 13 * scale))
    }
}

