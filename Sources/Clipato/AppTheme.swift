import AppKit
import Observation
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var saved: AppTheme {
        UserDefaults.standard.string(forKey: "theme").flatMap(AppTheme.init(rawValue:)) ?? .system
    }
}

struct AppearanceColors: Equatable {
    var accent: UInt32
    var background: UInt32
    var foreground: UInt32

    static let defaultLight = AppearancePreset.oat.light
    static let defaultDark = AppearancePreset.oat.dark

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func rgb(_ color: NSColor) -> UInt32 {
        let color = color.usingColorSpace(.sRGB)!
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return (channel(color.redComponent) << 16) | (channel(color.greenComponent) << 8) | channel(color.blueComponent)
    }
}

enum AppearancePreset: String, CaseIterable, Identifiable {
    case oat, apricot, tea, rose, osmanthus, cocoa

    var id: Self { self }

    var title: String {
        switch self {
        case .oat: return L("石墨")
        case .apricot: return L("蓝色")
        case .tea: return L("绿色")
        case .rose: return L("粉色")
        case .osmanthus: return L("紫色")
        case .cocoa: return L("橙色")
        }
    }

    var light: AppearanceColors {
        switch self {
        case .oat: return AppearanceColors(accent: 0x24262B, background: 0xEFF0F2, foreground: 0x202228)
        case .apricot: return AppearanceColors(accent: 0x1D58BD, background: 0xEFF0F2, foreground: 0x202228)
        case .tea: return AppearanceColors(accent: 0x0E6847, background: 0xEFF0F2, foreground: 0x202228)
        case .rose: return AppearanceColors(accent: 0xA32B64, background: 0xEFF0F2, foreground: 0x202228)
        case .osmanthus: return AppearanceColors(accent: 0x6344B3, background: 0xEFF0F2, foreground: 0x202228)
        case .cocoa: return AppearanceColors(accent: 0x9E4009, background: 0xEFF0F2, foreground: 0x202228)
        }
    }

    var dark: AppearanceColors {
        switch self {
        case .oat: return AppearanceColors(accent: 0xE5E7EB, background: 0x17191D, foreground: 0xF4F4F5)
        case .apricot: return AppearanceColors(accent: 0x79B2FF, background: 0x17191D, foreground: 0xF4F4F5)
        case .tea: return AppearanceColors(accent: 0x65D8AE, background: 0x17191D, foreground: 0xF4F4F5)
        case .rose: return AppearanceColors(accent: 0xF58FBA, background: 0x17191D, foreground: 0xF4F4F5)
        case .osmanthus: return AppearanceColors(accent: 0xB8A0FF, background: 0x17191D, foreground: 0xF4F4F5)
        case .cocoa: return AppearanceColors(accent: 0xFFB168, background: 0x17191D, foreground: 0xF4F4F5)
        }
    }
}

extension Notification.Name {
    static let clipatoAppearanceDidChange = Notification.Name("ClipatoAppearanceDidChange")
}

enum ConsoleFontSize: Int, CaseIterable, Identifiable {
    case small = 12, normal = 14, large = 16, extraLarge = 18, largest = 20

    var id: Int { rawValue }
    var scale: CGFloat { CGFloat(rawValue) / CGFloat(Self.normal.rawValue) }
    var title: String {
        switch self {
        case .small: return L("较小")
        case .normal: return L("正常")
        case .large: return L("较大")
        case .extraLarge: return L("很大")
        case .largest: return L("最大")
        }
    }
}

@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()
    private(set) var light: AppearanceColors
    private(set) var dark: AppearanceColors
    private(set) var palette: AppearancePalette
    private(set) var consoleFontSize: ConsoleFontSize
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        consoleFontSize = ConsoleFontSize(rawValue: defaults.integer(forKey: "appearance.consoleFontSize")) ?? .normal
        let light = Self.load("light", defaults: defaults, initial: .defaultLight)
        let dark = Self.load("dark", defaults: defaults, initial: .defaultDark)
        let migratedLight = Self.migrateFactoryColors(light, dark: false)
        let migratedDark = Self.migrateFactoryColors(dark, dark: true)
        self.light = migratedLight
        self.dark = migratedDark
        palette = AppearancePalette(light: migratedLight, dark: migratedDark)
        if migratedLight != light { save(migratedLight, mode: "light") }
        if migratedDark != dark { save(migratedDark, mode: "dark") }
    }

    func update(_ colors: AppearanceColors, dark isDark: Bool) {
        guard colors != (isDark ? dark : light) else { return }
        if isDark { dark = colors } else { light = colors }
        save(colors, mode: isDark ? "dark" : "light")
        palette = AppearancePalette(light: light, dark: dark)
        NotificationCenter.default.post(name: .clipatoAppearanceDidChange, object: self)
    }

    var preset: AppearancePreset? {
        AppearancePreset.allCases.first { $0.light == light && $0.dark == dark }
    }

    func apply(_ preset: AppearancePreset) {
        let light = preset.light
        let dark = preset.dark
        guard light != self.light || dark != self.dark else { return }
        self.light = light
        self.dark = dark
        save(light, mode: "light")
        save(dark, mode: "dark")
        palette = AppearancePalette(light: light, dark: dark)
        NotificationCenter.default.post(name: .clipatoAppearanceDidChange, object: self)
    }

    func restoreDefaults() { apply(.oat) }

    func setConsoleFontSize(_ size: ConsoleFontSize) {
        guard size != consoleFontSize else { return }
        consoleFontSize = size
        defaults.set(size.rawValue, forKey: "appearance.consoleFontSize")
    }

    private static func migrateFactoryColors(_ colors: AppearanceColors, dark: Bool) -> AppearanceColors {
        // Migrate only untouched factory palettes; one edited component makes the entire mode custom.
        if dark {
            switch colors {
            case AppearanceColors(accent: 0xFFBD6A, background: 0x25221E, foreground: 0xFFF3E5),
                 AppearanceColors(accent: 0x87B0E3, background: 0x1C1C1C, foreground: 0xEBEBEB),
                 AppearanceColors(accent: 0xBD91F5, background: 0x25231F, foreground: 0xE8E0CD),
                 AppearanceColors(accent: 0xC8AA7C, background: 0x292620, foreground: 0xE7DECF),
                 AppearanceColors(accent: 0xE5E7EB, background: 0x17191D, foreground: 0xF4F4F5):
                return AppearancePreset.oat.dark
            case AppearanceColors(accent: 0xFFA17A, background: 0x29211E, foreground: 0xFFF0E9),
                 AppearanceColors(accent: 0xD7A07E, background: 0x2D2521, foreground: 0xF0DDD0),
                 AppearanceColors(accent: 0x79B2FF, background: 0x142238, foreground: 0xEAF2FF):
                return AppearancePreset.apricot.dark
            case AppearanceColors(accent: 0xAAD782, background: 0x22271F, foreground: 0xF0F6E6),
                 AppearanceColors(accent: 0xA9B788, background: 0x272A22, foreground: 0xE1E6D2),
                 AppearanceColors(accent: 0x65D8AE, background: 0x122B25, foreground: 0xE5F8EF):
                return AppearancePreset.tea.dark
            case AppearanceColors(accent: 0xFFA2BC, background: 0x2A2025, foreground: 0xFFF0F5),
                 AppearanceColors(accent: 0xCCA0A8, background: 0x2D2427, foreground: 0xEBDDDE),
                 AppearanceColors(accent: 0xF58FBA, background: 0x331E2B, foreground: 0xFDECF4):
                return AppearancePreset.rose.dark
            case AppearanceColors(accent: 0xF0CB66, background: 0x28241B, foreground: 0xFFF5D9),
                 AppearanceColors(accent: 0xCBB274, background: 0x2D281F, foreground: 0xEEE2C8),
                 AppearanceColors(accent: 0xB8A0FF, background: 0x241D36, foreground: 0xF3EDFF):
                return AppearancePreset.osmanthus.dark
            case AppearanceColors(accent: 0xEFB28E, background: 0x29211D, foreground: 0xFFF0E6),
                 AppearanceColors(accent: 0xC5A491, background: 0x292321, foreground: 0xE7DAD1),
                 AppearanceColors(accent: 0xFFB168, background: 0x34251C, foreground: 0xFFF1E2):
                return AppearancePreset.cocoa.dark
            default: return colors
            }
        }
        switch colors {
        case AppearanceColors(accent: 0x995000, background: 0xFFFBF5, foreground: 0x2E2923),
             AppearanceColors(accent: 0x335E8F, background: 0xF7F7F7, foreground: 0x202020),
             AppearanceColors(accent: 0x9338FF, background: 0xF7EFD6, foreground: 0x0D0D0D),
             AppearanceColors(accent: 0x705638, background: 0xF3EBDD, foreground: 0x3E3932),
             AppearanceColors(accent: 0x24262B, background: 0xEFF0F2, foreground: 0x202228):
            return AppearancePreset.oat.light
        case AppearanceColors(accent: 0xB13C14, background: 0xFFF8F3, foreground: 0x33251F),
             AppearanceColors(accent: 0x855038, background: 0xF6E9DF, foreground: 0x46382F),
             AppearanceColors(accent: 0x1D58BD, background: 0xE5EFFC, foreground: 0x172A45):
            return AppearancePreset.apricot.light
        case AppearanceColors(accent: 0x33713D, background: 0xFAFCEF, foreground: 0x252D21),
             AppearanceColors(accent: 0x54623D, background: 0xF1EEDF, foreground: 0x3B4032),
             AppearanceColors(accent: 0x0E6847, background: 0xE0F2E9, foreground: 0x17392B):
            return AppearancePreset.tea.light
        case AppearanceColors(accent: 0xB23559, background: 0xFFF7F8, foreground: 0x32232A),
             AppearanceColors(accent: 0x7C4C57, background: 0xF3E8E4, foreground: 0x49373A),
             AppearanceColors(accent: 0xA32B64, background: 0xF8E5EF, foreground: 0x442337):
            return AppearancePreset.rose.light
        case AppearanceColors(accent: 0x886000, background: 0xFFFCEF, foreground: 0x30291A),
             AppearanceColors(accent: 0x755824, background: 0xF5ECD8, foreground: 0x453C2D),
             AppearanceColors(accent: 0x6344B3, background: 0xEDE7FA, foreground: 0x302342):
            return AppearancePreset.osmanthus.light
        case AppearanceColors(accent: 0x9C4928, background: 0xFFF9F5, foreground: 0x30241F),
             AppearanceColors(accent: 0x6E5448, background: 0xEEE7E1, foreground: 0x413733),
             AppearanceColors(accent: 0x9E4009, background: 0xFFF0D6, foreground: 0x482B1C):
            return AppearancePreset.cocoa.light
        default: return colors
        }
    }

    private static func load(_ mode: String, defaults: UserDefaults, initial: AppearanceColors) -> AppearanceColors {
        func value(_ field: String, initial: UInt32) -> UInt32 {
            guard let value = defaults.object(forKey: "appearance.\(mode).\(field)") as? NSNumber else { return initial }
            return value.uint32Value
        }
        return AppearanceColors(accent: value("accent", initial: initial.accent),
                                background: value("background", initial: initial.background),
                                foreground: value("foreground", initial: initial.foreground))
    }

    private func save(_ colors: AppearanceColors, mode: String) {
        defaults.set(colors.accent, forKey: "appearance.\(mode).accent")
        defaults.set(colors.background, forKey: "appearance.\(mode).background")
        defaults.set(colors.foreground, forKey: "appearance.\(mode).foreground")
    }
}

// Cache resolved colors until a setting changes; thumbnail redraws do not allocate new dynamic colors.
struct AppearancePalette {
    let background: Color
    let sidebar: Color
    let card: Color
    let canvas: Color
    let accent: Color
    let foreground: Color
    let onAccent: Color
    let muted: Color
    let warning: Color
    let line: Color

    init(light: AppearanceColors, dark: AppearanceColors) {
        let nativeLight = AppearancePreset.allCases.contains { $0.light == light }
        let nativeDark = AppearancePreset.allCases.contains { $0.dark == dark }
        let lightBackground = AppearanceColors.color(light.background)
        let darkBackground = AppearanceColors.color(dark.background)
        let lightForeground = AppearanceColors.color(light.foreground)
        let darkForeground = AppearanceColors.color(dark.foreground)
        let lightAccent = AppearanceColors.color(light.accent)
        let darkAccent = AppearanceColors.color(dark.accent)
        // Factory values identify a preset; native surfaces remain semantic, while edited modes retain their RGB colors.
        background = Self.adaptive(light: nativeLight ? .windowBackgroundColor : lightBackground,
                                   dark: nativeDark ? .windowBackgroundColor : darkBackground)
        sidebar = Self.adaptive(light: nativeLight ? .windowBackgroundColor : Self.mix(lightBackground, with: lightForeground, amount: 0.018),
                                dark: nativeDark ? .windowBackgroundColor : Self.mix(darkBackground, with: darkForeground, amount: 0.025))
        card = Self.adaptive(light: nativeLight ? .controlBackgroundColor : Self.mix(lightBackground, with: .white, amount: 0.68),
                             dark: nativeDark ? .controlBackgroundColor : Self.mix(darkBackground, with: darkForeground, amount: 0.055))
        canvas = Self.adaptive(light: nativeLight ? .textBackgroundColor : Self.mix(lightBackground, with: lightForeground, amount: 0.025),
                               dark: nativeDark ? .textBackgroundColor : Self.mix(darkBackground, with: .black, amount: 0.15))
        accent = Self.adaptive(light: lightAccent, dark: darkAccent)
        foreground = Self.adaptive(light: nativeLight ? .labelColor : lightForeground,
                                   dark: nativeDark ? .labelColor : darkForeground)
        onAccent = Self.adaptive(light: Self.contrastingText(for: lightAccent), dark: Self.contrastingText(for: darkAccent))
        muted = Self.adaptive(light: nativeLight ? .secondaryLabelColor : Self.mix(lightForeground, with: lightBackground, amount: 0.19),
                              dark: nativeDark ? .secondaryLabelColor : Self.mix(darkForeground, with: darkBackground, amount: 0.32))
        warning = Self.adaptive(light: AppearanceColors.color(0x934500), dark: AppearanceColors.color(0xFFC66D))
        line = Self.adaptive(light: nativeLight ? .separatorColor : Self.mix(lightBackground, with: lightForeground, amount: 0.16),
                             dark: nativeDark ? .separatorColor : Self.mix(darkBackground, with: darkForeground, amount: 0.18))
    }

    static func contrastingText(for color: NSColor) -> NSColor {
        let color = color.usingColorSpace(.sRGB)!
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        return luminance > 0.179 ? .black : .white
    }

    private static func mix(_ first: NSColor, with second: NSColor, amount: CGFloat) -> NSColor {
        let first = first.usingColorSpace(.sRGB)!
        let second = second.usingColorSpace(.sRGB)!
        return NSColor(srgbRed: first.redComponent * (1 - amount) + second.redComponent * amount,
                       green: first.greenComponent * (1 - amount) + second.greenComponent * amount,
                       blue: first.blueComponent * (1 - amount) + second.blueComponent * amount, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

enum Palette {
    static var background: Color { AppearanceSettings.shared.palette.background }
    static var sidebar: Color { AppearanceSettings.shared.palette.sidebar }
    static var card: Color { AppearanceSettings.shared.palette.card }
    static var canvas: Color { AppearanceSettings.shared.palette.canvas }
    static var accent: Color { AppearanceSettings.shared.palette.accent }
    static var foreground: Color { AppearanceSettings.shared.palette.foreground }
    static var onAccent: Color { AppearanceSettings.shared.palette.onAccent }
    static var muted: Color { AppearanceSettings.shared.palette.muted }
    static var warning: Color { AppearanceSettings.shared.palette.warning }
    static var line: Color { AppearanceSettings.shared.palette.line }
}
