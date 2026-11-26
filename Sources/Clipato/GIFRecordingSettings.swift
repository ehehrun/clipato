import Foundation

enum GIFRecordingQuality: String, CaseIterable, Identifiable, Sendable {
    case compact
    case balanced
    case high

    var id: Self { self }
    var title: String {
        switch self {
        case .compact: return L("更小文件")
        case .balanced: return L("均衡")
        case .high: return L("更高清晰度")
        }
    }

    var maximumDimension: Int {
        switch self {
        case .compact: return 800
        case .balanced: return 1280
        case .high: return 1920
        }
    }
}

struct GIFRecordingSettings: Equatable, Sendable {
    static let frameRates = [10, 15, 24, 30]
    var frameRate = 30
    var quality: GIFRecordingQuality = .balanced
    var maximumDimension: Int { quality.maximumDimension }

    func validate() throws {
        guard Self.frameRates.contains(frameRate) else { throw GIFRecordingError.invalidSettings }
    }
}

enum GIFRecordingError: LocalizedError {
    case invalidSettings
    case encoding
    case invalidEncodedFrame
    case invalidDuration
    case finished

    var errorDescription: String? {
        switch self {
        case .invalidSettings: return L("GIF 帧率须为 10、15、24 或 30，画面尺寸须在 1 到 1920 像素之间。")
        case .encoding: return L("无法编码 GIF 画面。")
        case .invalidEncodedFrame: return L("系统 GIF 编码器返回了无效的画面。")
        case .invalidDuration: return L("GIF 结束时间早于最后一帧，无法保存完整录制。")
        case .finished: return L("GIF 录制已经结束。")
        }
    }
}
