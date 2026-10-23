import Foundation
import ClipatoCore
import Observation
import os

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case tibetan = "bo"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .tibetan: return "བོད་ཡིག"
        }
    }

    static func systemLanguage(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier)
            switch language.languageCode?.identifier {
            case "en": return .english
            case "zh": return language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese
            case "ja": return .japanese
            case "ko": return .korean
            case "bo": return .tibetan
            default: continue
            }
        }
        // English is the app's documented language when none of the system preferences is supported.
        return .english
    }
}

extension Notification.Name {
    static let clipatoLanguageDidChange = Notification.Name("ClipatoLanguageDidChange")
}

@Observable
// Reads use the state lock; preference changes are confined to the main actor.
final class LanguageSettings: @unchecked Sendable {
    static let shared = LanguageSettings()

    static let resourceBundle: Bundle = {
        // SwiftPM's generated accessor searches beside a CLI executable, not Contents/Resources.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle(url: Bundle.main.resourceURL!.appendingPathComponent("Clipato_Clipato.bundle"))!
        }
        return .module
    }()

    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        AppLanguage.allCases.filter { $0 != .system }.map { language in
            (language, Bundle(url: resourceBundle.url(forResource: language.rawValue.lowercased(), withExtension: "lproj")!)!)
        }
    )

    private struct State {
        var language: AppLanguage
        var resolvedLanguage: AppLanguage
        var locale: Locale
        var bundle: Bundle

        init(language: AppLanguage, preferredLanguages: [String]) {
            let resolved = language == .system ? AppLanguage.systemLanguage(preferredLanguages: preferredLanguages) : language
            self.language = language
            resolvedLanguage = resolved
            locale = Locale(identifier: resolved.rawValue)
            bundle = LanguageSettings.bundles[resolved]!
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let state: OSAllocatedUnfairLock<State>

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        let language = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .system
        state = OSAllocatedUnfairLock(initialState: State(language: language, preferredLanguages: preferredLanguages))
    }

    var language: AppLanguage {
        access(keyPath: \.language)
        return state.withLock { $0.language }
    }

    var resolvedLanguage: AppLanguage {
        access(keyPath: \.language)
        return state.withLock { $0.resolvedLanguage }
    }

    var locale: Locale {
        access(keyPath: \.language)
        return state.withLock { $0.locale }
    }

    @MainActor
    func setLanguage(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        let updated = State(language: language, preferredLanguages: preferredLanguages)
        let unchanged = state.withLock { $0.language == updated.language && $0.resolvedLanguage == updated.resolvedLanguage }
        guard !unchanged else { return }
        withMutation(keyPath: \.language) {
            state.withLock { $0 = updated }
            defaults.set(language.rawValue, forKey: "language")
        }
        NotificationCenter.default.post(name: .clipatoLanguageDidChange, object: self)
    }

    func localized(_ value: String.LocalizationValue) -> String {
        access(keyPath: \.language)
        let context = state.withLock { ($0.bundle, $0.locale) }
        return String(localized: value, bundle: context.0, locale: context.1)
    }

    func localizedKey(_ key: String) -> String {
        access(keyPath: \.language)
        let bundle = state.withLock { $0.bundle }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

func L(_ value: String.LocalizationValue) -> String {
    LanguageSettings.shared.localized(value)
}

func workspaceErrorDescription(_ error: Error) -> String {
    switch error {
    case let error as CollageError:
        switch error {
        case .emptySelection: return L("请至少选择一张图片。")
        case .invalidSetting(let message): return LanguageSettings.shared.localizedKey(message)
        case .insufficientGrid(let capacity, let count):
            return L("当前网格只有 \(capacity) 个位置，无法放下 \(count) 张图片。请增加行数或列数。")
        case .canvasTooLarge(let width, let height):
            return L("画布尺寸 \(width) × \(height) 超过限制。请降低缩放比例、元素最大宽高或行列数。")
        case .contextCreationFailed: return L("无法创建拼图画布。")
        }
    case let error as LongScreenshotError:
        switch error {
        case .invalidSetting(let message): return LanguageSettings.shared.localizedKey(message)
        case .imageReadFailed: return L("无法读取长图截图的像素。")
        }
    default: return error.localizedDescription
    }
}

func imageProcessingErrorDescription(_ error: Error) -> String {
    if error is ImageGridError { return imageGridErrorDescription(error) }
    guard let processing = error as? ImageProcessingError else { return error.localizedDescription }
    switch processing {
    case .invalidDimensions(let width, let height): return L("尺寸须为 1–32768 px：\(width) × \(height)。")
    case .invalidWebPDimensions(let width, let height): return L("WebP 单边不能超过 16383 px：\(width) × \(height)。")
    case .canvasTooLarge(let width, let height): return L("图片超过 6400 万像素：\(width) × \(height)。请先减小尺寸。")
    case .invalidQuality: return L("导出质量须为 1% 到 100%。")
    case .invalidTargetBytes: return L("目标文件大小必须大于 0。")
    case .unreadableImage(let url): return L("无法读取图片：\(url.path)")
    case .allocationFailed: return L("无法分配图片处理所需的内存。")
    case .encodingFailed(let format): return L("无法编码为 \(format.rawValue.uppercased())。")
    case .targetUnreachable(let target, let smallest): return L("无法达到 \(target) 字节的目标，已尝试的最小结果为 \(smallest) 字节。")
    }
}

func imageGridErrorDescription(_ error: Error) -> String {
    guard let grid = error as? ImageGridError else { return imageProcessingErrorDescription(error) }
    switch grid {
    case .invalidDivisions: return L("请选择四宫格或九宫格。")
    case .invalidTileSize: return L("每张切片边长须为 1–4096 px。")
    case .invalidGap: return L("间隙须为非负的原图像素，且不能超过图片范围。")
    case .requiresCrop: return L("请先选择正方形裁切区域。")
    case .invalidCrop: return L("裁切区域须位于原图内，并使用整数像素的正方形。")
    case .sourceTooSmall(let side): return L("原图或裁切区域至少需要 \(side) × \(side) px；请选择更小的切片尺寸。")
    case .invalidIndex: return L("切片位置超出宫格范围。")
    }
}
