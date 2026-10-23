import AppKit
import Observation
import os
import SwiftUI
import XCTest
@testable import Clipato

final class AppearanceSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "ClipatoAppearanceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    func testNewInstallUsesDefaultPresetForBothAppearances() {
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.light, .defaultLight)
        XCTAssertEqual(settings.dark, .defaultDark)
        XCTAssertEqual(settings.preset, .oat)
        XCTAssertNil(defaults.object(forKey: "theme"))
    }

    func testConsoleFontSizeDefaultsToNormalAndPersistsIndependentlyOfColors() {
        let settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.consoleFontSize, .normal)
        XCTAssertEqual(settings.consoleFontSize.scale, 1)
        for size in ConsoleFontSize.allCases {
            settings.setConsoleFontSize(size)
            XCTAssertEqual(AppearanceSettings(defaults: defaults).consoleFontSize, size)
        }
        settings.apply(.rose)
        settings.restoreDefaults()
        XCTAssertEqual(settings.consoleFontSize, .largest)
        settings.setConsoleFontSize(.normal)
        XCTAssertEqual(AppearanceSettings(defaults: defaults).consoleFontSize.scale, 1)
        XCTAssertEqual(settings.preset, .oat)
    }

    func testUnsupportedSavedFontSizeDoesNotProduceAnInvalidScale() {
        defaults.set(99, forKey: "appearance.consoleFontSize")
        XCTAssertEqual(AppearanceSettings(defaults: defaults).consoleFontSize, .normal)
    }

    func testFontSizeChangeInvalidatesOnlyTypographyObservation() {
        let settings = AppearanceSettings(defaults: defaults)
        let fontChanged = OSAllocatedUnfairLock(initialState: false)
        let paletteChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = settings.consoleFontSize } onChange: {
            fontChanged.withLock { $0 = true }
        }
        withObservationTracking { _ = settings.palette } onChange: {
            paletteChanged.withLock { $0 = true }
        }
        settings.setConsoleFontSize(.normal)
        XCTAssertFalse(fontChanged.withLock { $0 })
        settings.setConsoleFontSize(.largest)
        XCTAssertTrue(fontChanged.withLock { $0 })
        XCTAssertFalse(paletteChanged.withLock { $0 })
    }

    func testCustomColorsSurviveRelaunchAndKeepOtherModeIndependent() {
        let settings = AppearanceSettings(defaults: defaults)
        let light = AppearanceColors(accent: 0x9900DD, background: 0xFFF4DA, foreground: 0x172D32)
        settings.update(light, dark: false)
        let relaunched = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(relaunched.light, light)
        XCTAssertEqual(relaunched.dark, .defaultDark)
        XCTAssertEqual(resolved(relaunched.palette.background, appearance: .aqua), light.background)
        assertNativeColor(relaunched.palette.background, equals: .windowBackgroundColor, appearance: .darkAqua)
        XCTAssertEqual(resolved(relaunched.palette.accent, appearance: .aqua), light.accent)
        XCTAssertEqual(resolved(relaunched.palette.foreground, appearance: .aqua), light.foreground)
    }

    func testAllPresetsPersistAndResetWithoutChangingAppearanceMode() {
        defaults.set("system", forKey: "theme")
        let settings = AppearanceSettings(defaults: defaults)
        for preset in AppearancePreset.allCases {
            settings.apply(preset)
            let relaunched = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(relaunched.light, preset.light)
            XCTAssertEqual(relaunched.dark, preset.dark)
            XCTAssertEqual(relaunched.preset, preset)
        }
        settings.restoreDefaults()
        let restored = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(restored.light, .defaultLight)
        XCTAssertEqual(restored.dark, .defaultDark)
        XCTAssertEqual(restored.preset, .oat)
        XCTAssertEqual(defaults.string(forKey: "theme"), "system")
    }

    func testApplyingPresetNotifiesOnceAfterBothModesAndPaletteUpdate() {
        let settings = AppearanceSettings(defaults: defaults)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .clipatoAppearanceDidChange,
                                                              object: settings, queue: nil) { _ in
            calls.withLock { $0 += 1 }
            XCTAssertEqual(settings.preset, .rose)
            self.assertNativeColor(settings.palette.background, equals: .windowBackgroundColor, appearance: .aqua)
            self.assertNativeColor(settings.palette.background, equals: .windowBackgroundColor, appearance: .darkAqua)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        settings.apply(.rose)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        settings.apply(.rose)
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testEditingOneColorMakesPresetCustomAndRestoreReturnsToDefault() {
        let settings = AppearanceSettings(defaults: defaults)
        settings.apply(.tea)
        var colors = settings.light
        colors.foreground = 0x344536
        settings.update(colors, dark: false)
        XCTAssertNil(settings.preset)
        XCTAssertEqual(settings.dark, AppearancePreset.tea.dark)
        settings.restoreDefaults()
        XCTAssertEqual(settings.preset, .oat)
    }

    func testOldFactoryPalettesMigrateToDefaultAndPersist() {
        let oldPalettes: [(AppearanceColors, AppearanceColors)] = [
            (AppearanceColors(accent: 0x335E8F, background: 0xF7F7F7, foreground: 0x202020),
             AppearanceColors(accent: 0x87B0E3, background: 0x1C1C1C, foreground: 0xEBEBEB)),
            (AppearanceColors(accent: 0x9338FF, background: 0xF7EFD6, foreground: 0x0D0D0D),
             AppearanceColors(accent: 0xBD91F5, background: 0x25231F, foreground: 0xE8E0CD))
        ]
        defaults.set("dark", forKey: "theme")
        for (light, dark) in oldPalettes {
            save(light, mode: "light")
            save(dark, mode: "dark")
            XCTAssertEqual(AppearanceSettings(defaults: defaults).preset, .oat)
            XCTAssertEqual(defaults.integer(forKey: "appearance.light.accent"), Int(AppearanceColors.defaultLight.accent))
            XCTAssertEqual(defaults.integer(forKey: "appearance.dark.background"), Int(AppearanceColors.defaultDark.background))
            XCTAssertEqual(AppearanceSettings(defaults: defaults).preset, .oat)
        }
        XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
    }

    func testMigrationPreservesCustomModesEvenWhenOneComponentDiffers() {
        let oldLight = AppearanceColors(accent: 0x335E8F, background: 0xF7F7F7, foreground: 0x202020)
        let oldDark = AppearanceColors(accent: 0xBD91F5, background: 0x25231F, foreground: 0xE8E0CD)
        var customLight = oldLight
        customLight.accent += 1
        var customDark = oldDark
        customDark.foreground -= 1
        save(oldLight, mode: "light")
        save(customDark, mode: "dark")
        var settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.light, .defaultLight)
        XCTAssertEqual(settings.dark, customDark)
        save(customLight, mode: "light")
        save(oldDark, mode: "dark")
        settings = AppearanceSettings(defaults: defaults)
        XCTAssertEqual(settings.light, customLight)
        XCTAssertEqual(settings.dark, .defaultDark)
        XCTAssertNil(settings.preset)
    }

    func testPreviousWarmPresetsMigrateToCorrespondingCurrentPresetsAndPersist() {
        defaults.set("system", forKey: "theme")
        defaults.set(ConsoleFontSize.large.rawValue, forKey: "appearance.consoleFontSize")
        for (preset, light, dark) in previousWarmPalettes {
            save(light, mode: "light")
            save(dark, mode: "dark")
            let settings = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(settings.preset, preset)
            XCTAssertEqual(settings.light, preset.light)
            XCTAssertEqual(settings.dark, preset.dark)
            XCTAssertEqual(defaults.integer(forKey: "appearance.light.background"), Int(preset.light.background))
            XCTAssertEqual(defaults.integer(forKey: "appearance.dark.accent"), Int(preset.dark.accent))
            XCTAssertEqual(AppearanceSettings(defaults: defaults).preset, preset)
            XCTAssertEqual(settings.consoleFontSize, .large)
        }
        XCTAssertEqual(defaults.string(forKey: "theme"), "system")
    }

    func testWarmPresetMigrationPreservesEachCustomComponentAndTheOtherModesPreset() {
        let fields: [WritableKeyPath<AppearanceColors, UInt32>] = [\.accent, \.background, \.foreground]
        for (preset, light, dark) in previousWarmPalettes {
            for isDark in [false, true] {
                for field in fields {
                    var custom = isDark ? dark : light
                    custom[keyPath: field] ^= 1
                    save(isDark ? light : custom, mode: "light")
                    save(isDark ? custom : dark, mode: "dark")
                    let settings = AppearanceSettings(defaults: defaults)
                    XCTAssertEqual(isDark ? settings.dark : settings.light, custom)
                    XCTAssertEqual(isDark ? settings.light : settings.dark, isDark ? preset.light : preset.dark)
                    XCTAssertNil(settings.preset)
                    let relaunched = AppearanceSettings(defaults: defaults)
                    XCTAssertEqual(isDark ? relaunched.dark : relaunched.light, custom)
                }
            }
        }
    }

    func testBrightWarmPresetsMigrateBothModesPersistAndRemainStableOnRelaunch() {
        defaults.set("dark", forKey: "theme")
        defaults.set(ConsoleFontSize.extraLarge.rawValue, forKey: "appearance.consoleFontSize")
        for (preset, light, dark) in brightWarmPalettes {
            save(light, mode: "light")
            save(dark, mode: "dark")
            let settings = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(settings.preset, preset)
            XCTAssertEqual(settings.light, preset.light)
            XCTAssertEqual(settings.dark, preset.dark)
            for (mode, colors) in [("light", preset.light), ("dark", preset.dark)] {
                XCTAssertEqual(defaults.integer(forKey: "appearance.\(mode).accent"), Int(colors.accent))
                XCTAssertEqual(defaults.integer(forKey: "appearance.\(mode).background"), Int(colors.background))
                XCTAssertEqual(defaults.integer(forKey: "appearance.\(mode).foreground"), Int(colors.foreground))
            }
            let persisted = defaults.persistentDomain(forName: suiteName)! as NSDictionary
            let relaunched = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(relaunched.preset, preset)
            XCTAssertEqual(relaunched.light, settings.light)
            XCTAssertEqual(relaunched.dark, settings.dark)
            XCTAssertEqual(defaults.persistentDomain(forName: suiteName)! as NSDictionary, persisted)
            XCTAssertEqual(relaunched.consoleFontSize, .extraLarge)
        }
        XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
    }

    func testBrightWarmMigrationPreservesEveryCustomFieldAndMigratesOnlyUntouchedMode() {
        let fields: [WritableKeyPath<AppearanceColors, UInt32>] = [\.accent, \.background, \.foreground]
        for (preset, light, dark) in brightWarmPalettes {
            for isDark in [false, true] {
                for field in fields {
                    var custom = isDark ? dark : light
                    custom[keyPath: field] ^= 1
                    save(isDark ? light : custom, mode: "light")
                    save(isDark ? custom : dark, mode: "dark")
                    let settings = AppearanceSettings(defaults: defaults)
                    XCTAssertEqual(isDark ? settings.dark : settings.light, custom)
                    XCTAssertEqual(isDark ? settings.light : settings.dark, isDark ? preset.light : preset.dark)
                    XCTAssertNil(settings.preset)
                    let customMode = isDark ? "dark" : "light"
                    XCTAssertEqual(defaults.integer(forKey: "appearance.\(customMode).accent"), Int(custom.accent))
                    XCTAssertEqual(defaults.integer(forKey: "appearance.\(customMode).background"), Int(custom.background))
                    XCTAssertEqual(defaults.integer(forKey: "appearance.\(customMode).foreground"), Int(custom.foreground))
                    let relaunched = AppearanceSettings(defaults: defaults)
                    XCTAssertEqual(isDark ? relaunched.dark : relaunched.light, custom)
                    XCTAssertEqual(isDark ? relaunched.light : relaunched.dark, isDark ? preset.light : preset.dark)
                    XCTAssertNil(relaunched.preset)
                }
            }
        }
    }

    func testTintedFactoryPresetsBecomeNeutralWithoutChangingTheirAccentOrPreferences() {
        defaults.set("dark", forKey: "theme")
        defaults.set(ConsoleFontSize.large.rawValue, forKey: "appearance.consoleFontSize")
        for (preset, light, dark) in tintedPalettes {
            save(light, mode: "light")
            save(dark, mode: "dark")
            let settings = AppearanceSettings(defaults: defaults)
            XCTAssertEqual(settings.preset, preset)
            XCTAssertEqual(settings.light, preset.light)
            XCTAssertEqual(settings.dark, preset.dark)
            XCTAssertEqual(settings.light.accent, light.accent)
            XCTAssertEqual(settings.dark.accent, dark.accent)
            XCTAssertEqual(settings.light.background, AppearanceColors.defaultLight.background)
            XCTAssertEqual(settings.dark.background, AppearanceColors.defaultDark.background)
            XCTAssertEqual(settings.light.foreground, AppearanceColors.defaultLight.foreground)
            XCTAssertEqual(settings.dark.foreground, AppearanceColors.defaultDark.foreground)
            let persisted = defaults.persistentDomain(forName: suiteName)! as NSDictionary
            XCTAssertEqual(AppearanceSettings(defaults: defaults).preset, preset)
            XCTAssertEqual(defaults.persistentDomain(forName: suiteName)! as NSDictionary, persisted)
            XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
            XCTAssertEqual(settings.consoleFontSize, .large)
        }
    }

    func testTintedFactoryMigrationPreservesEveryCustomFieldAndOnlyMigratesUntouchedMode() {
        let fields: [WritableKeyPath<AppearanceColors, UInt32>] = [\.accent, \.background, \.foreground]
        for (preset, light, dark) in tintedPalettes {
            for isDark in [false, true] {
                for field in fields {
                    var custom = isDark ? dark : light
                    custom[keyPath: field] ^= 1
                    save(isDark ? light : custom, mode: "light")
                    save(isDark ? custom : dark, mode: "dark")
                    let settings = AppearanceSettings(defaults: defaults)
                    let customAppearance: NSAppearance.Name = isDark ? .darkAqua : .aqua
                    XCTAssertEqual(isDark ? settings.dark : settings.light, custom)
                    XCTAssertEqual(resolved(settings.palette.background, appearance: customAppearance), custom.background)
                    XCTAssertEqual(resolved(settings.palette.foreground, appearance: customAppearance), custom.foreground)
                    XCTAssertEqual(isDark ? settings.light : settings.dark, isDark ? preset.light : preset.dark)
                    assertNativeColor(settings.palette.background, equals: .windowBackgroundColor,
                                      appearance: isDark ? .aqua : .darkAqua)
                    XCTAssertNil(settings.preset)
                    let relaunched = AppearanceSettings(defaults: defaults)
                    XCTAssertEqual(isDark ? relaunched.dark : relaunched.light, custom)
                    XCTAssertNil(relaunched.preset)
                }
            }
        }
    }

    func testPresetSurfacesAndTextFollowNativeSemanticsInLightDarkAndIncreasedContrast() {
        for preset in AppearancePreset.allCases {
            let palette = AppearancePalette(light: preset.light, dark: preset.dark)
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                assertNativeColor(palette.background, equals: .windowBackgroundColor, appearance: appearance)
                assertNativeColor(palette.sidebar, equals: .windowBackgroundColor, appearance: appearance)
                assertNativeColor(palette.card, equals: .controlBackgroundColor, appearance: appearance)
                assertNativeColor(palette.canvas, equals: .textBackgroundColor, appearance: appearance)
                assertNativeColor(palette.foreground, equals: .labelColor, appearance: appearance)
                assertNativeColor(palette.muted, equals: .secondaryLabelColor, appearance: appearance)
                assertNativeColor(palette.line, equals: .separatorColor, appearance: appearance)
            }
        }
    }

    func testPresetPrimaryTextAndButtonLabelsStayReadableAcrossTheirSurfaces() {
        for preset in AppearancePreset.allCases {
            let palette = AppearancePalette(light: preset.light, dark: preset.dark)
            for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                let accent = resolved(palette.accent, appearance: appearance)
                let sidebar = resolved(palette.sidebar, appearance: appearance)
                let surfaces = [palette.background, palette.card, palette.sidebar, palette.canvas]
                    .map { resolved($0, appearance: appearance) }
                    + [blend(sidebar, accent, fraction: 0.10)]
                for surface in surfaces {
                    for color in [palette.foreground, palette.warning] {
                        let text = composited(color, over: surface, appearance: appearance)
                        XCTAssertGreaterThanOrEqual(contrast(text, surface), 4.5, "\(preset.title) \(appearance.rawValue)")
                    }
                }
                // Secondary labels retain the system's contrast and opacity; accent colors identify controls rather than body text.
                XCTAssertGreaterThanOrEqual(contrast(resolved(palette.onAccent, appearance: appearance), accent), 4.5)
            }
        }
    }

    func testPaletteChangeNotifiesObservedViewsButIdenticalUpdateDoesNot() {
        let settings = AppearanceSettings(defaults: defaults)
        let notified = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = settings.palette.foreground
        } onChange: {
            notified.withLock { $0 = true }
        }
        settings.update(.defaultLight, dark: false)
        XCTAssertFalse(notified.withLock { $0 })
        var colors = settings.light
        colors.foreground = 0x4A2310
        settings.update(colors, dark: false)
        XCTAssertTrue(notified.withLock { $0 })
        XCTAssertEqual(resolved(settings.palette.foreground, appearance: .aqua), 0x4A2310)
    }

    func testAccentTextKeepsContrastForBrightAndDarkCustomColors() {
        XCTAssertEqual(AppearanceColors.rgb(AppearancePalette.contrastingText(for: AppearanceColors.color(0xFFFF00))), 0x000000)
        XCTAssertEqual(AppearanceColors.rgb(AppearancePalette.contrastingText(for: AppearanceColors.color(0x170022))), 0xFFFFFF)
    }

    func testColorPickerClipsExtendedSRGBToDisplayableRGB() {
        let color = NSColor(colorSpace: .extendedSRGB, components: [-0.1, 0.5, 1.1, 1], count: 4)
        XCTAssertEqual(AppearanceColors.rgb(color), 0x0080FF)
    }

    private var previousWarmPalettes: [(AppearancePreset, AppearanceColors, AppearanceColors)] {
        [
            (.oat, AppearanceColors(accent: 0x705638, background: 0xF3EBDD, foreground: 0x3E3932),
             AppearanceColors(accent: 0xC8AA7C, background: 0x292620, foreground: 0xE7DECF)),
            (.apricot, AppearanceColors(accent: 0x855038, background: 0xF6E9DF, foreground: 0x46382F),
             AppearanceColors(accent: 0xD7A07E, background: 0x2D2521, foreground: 0xF0DDD0)),
            (.tea, AppearanceColors(accent: 0x54623D, background: 0xF1EEDF, foreground: 0x3B4032),
             AppearanceColors(accent: 0xA9B788, background: 0x272A22, foreground: 0xE1E6D2)),
            (.rose, AppearanceColors(accent: 0x7C4C57, background: 0xF3E8E4, foreground: 0x49373A),
             AppearanceColors(accent: 0xCCA0A8, background: 0x2D2427, foreground: 0xEBDDDE)),
            (.osmanthus, AppearanceColors(accent: 0x755824, background: 0xF5ECD8, foreground: 0x453C2D),
             AppearanceColors(accent: 0xCBB274, background: 0x2D281F, foreground: 0xEEE2C8)),
            (.cocoa, AppearanceColors(accent: 0x6E5448, background: 0xEEE7E1, foreground: 0x413733),
             AppearanceColors(accent: 0xC5A491, background: 0x292321, foreground: 0xE7DAD1))
        ]
    }

    private var brightWarmPalettes: [(AppearancePreset, AppearanceColors, AppearanceColors)] {
        [
            (.oat, AppearanceColors(accent: 0x995000, background: 0xFFFBF5, foreground: 0x2E2923),
             AppearanceColors(accent: 0xFFBD6A, background: 0x25221E, foreground: 0xFFF3E5)),
            (.apricot, AppearanceColors(accent: 0xB13C14, background: 0xFFF8F3, foreground: 0x33251F),
             AppearanceColors(accent: 0xFFA17A, background: 0x29211E, foreground: 0xFFF0E9)),
            (.tea, AppearanceColors(accent: 0x33713D, background: 0xFAFCEF, foreground: 0x252D21),
             AppearanceColors(accent: 0xAAD782, background: 0x22271F, foreground: 0xF0F6E6)),
            (.rose, AppearanceColors(accent: 0xB23559, background: 0xFFF7F8, foreground: 0x32232A),
             AppearanceColors(accent: 0xFFA2BC, background: 0x2A2025, foreground: 0xFFF0F5)),
            (.osmanthus, AppearanceColors(accent: 0x886000, background: 0xFFFCEF, foreground: 0x30291A),
             AppearanceColors(accent: 0xF0CB66, background: 0x28241B, foreground: 0xFFF5D9)),
            (.cocoa, AppearanceColors(accent: 0x9C4928, background: 0xFFF9F5, foreground: 0x30241F),
             AppearanceColors(accent: 0xEFB28E, background: 0x29211D, foreground: 0xFFF0E6))
        ]
    }

    private var tintedPalettes: [(AppearancePreset, AppearanceColors, AppearanceColors)] {
        [
            (.oat, AppearanceColors(accent: 0x24262B, background: 0xEFF0F2, foreground: 0x202228),
             AppearanceColors(accent: 0xE5E7EB, background: 0x17191D, foreground: 0xF4F4F5)),
            (.apricot, AppearanceColors(accent: 0x1D58BD, background: 0xE5EFFC, foreground: 0x172A45),
             AppearanceColors(accent: 0x79B2FF, background: 0x142238, foreground: 0xEAF2FF)),
            (.tea, AppearanceColors(accent: 0x0E6847, background: 0xE0F2E9, foreground: 0x17392B),
             AppearanceColors(accent: 0x65D8AE, background: 0x122B25, foreground: 0xE5F8EF)),
            (.rose, AppearanceColors(accent: 0xA32B64, background: 0xF8E5EF, foreground: 0x442337),
             AppearanceColors(accent: 0xF58FBA, background: 0x331E2B, foreground: 0xFDECF4)),
            (.osmanthus, AppearanceColors(accent: 0x6344B3, background: 0xEDE7FA, foreground: 0x302342),
             AppearanceColors(accent: 0xB8A0FF, background: 0x241D36, foreground: 0xF3EDFF)),
            (.cocoa, AppearanceColors(accent: 0x9E4009, background: 0xFFF0D6, foreground: 0x482B1C),
             AppearanceColors(accent: 0xFFB168, background: 0x34251C, foreground: 0xFFF1E2))
        ]
    }

    private func save(_ colors: AppearanceColors, mode: String) {
        defaults.set(colors.accent, forKey: "appearance.\(mode).accent")
        defaults.set(colors.background, forKey: "appearance.\(mode).background")
        defaults.set(colors.foreground, forKey: "appearance.\(mode).foreground")
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ rgb: UInt32) -> Double {
            let components = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)]
                .map { $0 / 255 }
                .map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let first = luminance(first)
        let second = luminance(second)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private func blend(_ background: UInt32, _ foreground: UInt32, fraction: Double) -> UInt32 {
        [16, 8, 0].reduce(0) { result, shift in
            let back = Double((background >> shift) & 255)
            let front = Double((foreground >> shift) & 255)
            return result | (UInt32((back * (1 - fraction) + front * fraction).rounded()) << shift)
        }
    }

    private func resolved(_ color: Color, appearance: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            result = AppearanceColors.rgb(NSColor(color))
        }
        return result
    }

    private func assertNativeColor(_ color: Color, equals native: NSColor, appearance: NSAppearance.Name,
                                   file: StaticString = #filePath, line: UInt = #line) {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let actual = NSColor(color).usingColorSpace(.sRGB)!
            let expected = native.usingColorSpace(.sRGB)!
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.0001, appearance.rawValue, file: file, line: line)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.0001, appearance.rawValue, file: file, line: line)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.0001, appearance.rawValue, file: file, line: line)
            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.0001, appearance.rawValue, file: file, line: line)
        }
    }

    private func composited(_ color: Color, over background: UInt32, appearance: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let color = NSColor(color).usingColorSpace(.sRGB)!
            result = blend(background, AppearanceColors.rgb(color), fraction: Double(color.alphaComponent))
        }
        return result
    }
}
