import Foundation
import Observation
import XCTest
import os
@testable import Clipato

@MainActor
final class LanguageSettingsTests: XCTestCase {
    func testSystemLanguageMatchesChineseScriptAndRegionAndPreferenceOrder() {
        for identifier in ["zh", "zh-CN", "zh-SG", "zh_Hans_TW"] {
            XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: [identifier]), .simplifiedChinese, identifier)
        }
        for identifier in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant-CN"] {
            XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: [identifier]), .traditionalChinese, identifier)
        }
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["fr-FR", "ja-JP", "en-US"]), .japanese)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["ko-KR"]), .korean)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["bo-CN"]), .tibetan)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["fr-FR", "mn-MN"]), .english)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: []), .english)
    }

    func testLanguageDefaultsToSystemAndPersistsWithoutChangingAppleLanguages() throws {
        let defaults = try makeDefaults()
        defaults.set(["ja-JP"], forKey: "AppleLanguages")
        defaults.set("oat", forKey: "appearance.preset")
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["zh-TW"])
        XCTAssertEqual(settings.language, .system)
        XCTAssertEqual(settings.resolvedLanguage, .traditionalChinese)

        settings.setLanguage(.korean, preferredLanguages: ["en"])
        let reopened = LanguageSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(reopened.language, .korean)
        XCTAssertEqual(reopened.resolvedLanguage, .korean)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ja-JP"])
        XCTAssertEqual(defaults.string(forKey: "appearance.preset"), "oat")

        reopened.setLanguage(.system, preferredLanguages: ["bo-CN"])
        XCTAssertEqual(reopened.resolvedLanguage, .tibetan)
        XCTAssertEqual(LanguageSettings(defaults: defaults, preferredLanguages: ["ja-JP"]).resolvedLanguage, .japanese)
    }

    func testLanguageChangeInvalidatesLocalizedViewReadsAndNotifiesAppKitOnce() throws {
        let settings = LanguageSettings(defaults: try makeDefaults(), preferredLanguages: ["zh-CN"])
        let changed = expectation(description: "A localized view is invalidated")
        withObservationTracking {
            _ = settings.localized("取消")
        } onChange: {
            changed.fulfill()
        }
        let notifications = OSAllocatedUnfairLock(initialState: 0)
        let observer = NotificationCenter.default.addObserver(forName: .clipatoLanguageDidChange, object: nil, queue: nil) { notification in
            if notification.object as? LanguageSettings === settings { notifications.withLock { $0 += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        settings.setLanguage(.english)
        settings.setLanguage(.english)
        XCTAssertEqual(notifications.withLock { $0 }, 1)
        wait(for: [changed], timeout: 1)
    }

    func testExplicitLanguageUsesItsOwnResourceTableAndNativeInterpolation() throws {
        let settings = LanguageSettings(defaults: try makeDefaults(), preferredLanguages: ["ja-JP"])
        settings.setLanguage(.english)
        XCTAssertEqual(settings.localized("取消"), "Cancel")
        settings.setLanguage(.simplifiedChinese)
        XCTAssertEqual(settings.localized("取消"), "取消")
        XCTAssertEqual(settings.localized("已选 \(7) 张"), "已选 7 张")
        settings.setLanguage(.english)
        let selected = settings.localized("已选 \(7) 张")
        XCTAssertTrue(selected.contains("7"))
        XCTAssertFalse(selected.contains("%"))
        XCTAssertFalse(selected.contains("已选"))
    }

    func testEverySelectableLanguageHasPackagedStringsAndNoMongolianOption() throws {
        let explicitLanguages = AppLanguage.allCases.filter { $0 != .system }
        XCTAssertEqual(Set(explicitLanguages.map(\.rawValue)), ["en", "zh-Hans", "zh-Hant", "ja", "ko", "bo"])
        var tables: [AppLanguage: [String: String]] = [:]
        let settings = LanguageSettings(defaults: try makeDefaults())
        for language in explicitLanguages {
            let directory = try XCTUnwrap(LanguageSettings.resourceBundle.url(forResource: language.rawValue.lowercased(), withExtension: "lproj"))
            let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            let table = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertFalse(table.isEmpty, language.rawValue)
            XCTAssertNotNil(table["取消"], language.rawValue)
            tables[language] = table
            settings.setLanguage(language)
            XCTAssertEqual(settings.localized("显示语言"), table["显示语言"], language.rawValue)
        }
        let base = try XCTUnwrap(tables[.simplifiedChinese])
        let placeholders = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+#0]*(?:\d+)?(?:\.\d+)?(?:hh|ll|h|l|z|j|t|q)?[@diuoxXfFeEgGaAcCsSp]"#)
        func arguments(_ string: String) -> [String] {
            placeholders.matches(in: string, range: NSRange(string.startIndex..., in: string)).map {
                (string as NSString).substring(with: $0.range)
            }
        }
        for (language, table) in tables {
            XCTAssertEqual(Set(table.keys), Set(base.keys), language.rawValue)
            for (key, value) in table {
                XCTAssertFalse(value.isEmpty, "\(language.rawValue): \(key)")
                XCTAssertEqual(arguments(key), arguments(value), "\(language.rawValue): \(key)")
            }
        }
    }

    func testBackgroundLocalizationUsesAConsistentSnapshotDuringLanguageChanges() async throws {
        let settings = LanguageSettings(defaults: try makeDefaults(), preferredLanguages: ["zh-CN"])
        settings.setLanguage(.simplifiedChinese)
        let reader = Task.detached { () -> String? in
            for _ in 0..<1_000 {
                let value = settings.localized("取消")
                if value != "Cancel" && value != "取消" { return value }
            }
            return nil
        }
        for _ in 0..<20 {
            settings.setLanguage(.english)
            settings.setLanguage(.simplifiedChinese)
        }
        let unexpectedValue = await reader.value
        XCTAssertNil(unexpectedValue)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "Clipato.LanguageSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
