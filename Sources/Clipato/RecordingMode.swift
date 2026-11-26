import Foundation

enum RecordingMode: String, CaseIterable, Identifiable {
    case keyframes
    case video
    case gif

    var id: Self { self }
    var title: String {
        switch self {
        case .keyframes: return L("关键帧录屏")
        case .video: return L("直接录屏")
        case .gif: return L("GIF 录制")
        }
    }
    var toolbarTitle: String {
        switch self {
        case .keyframes: return L("关键帧视频")
        case .video: return L("完整视频")
        case .gif: return L("GIF 动图")
        }
    }
    var toolbarSymbol: String {
        switch self {
        case .keyframes: return "rectangle.stack"
        case .video: return "video"
        case .gif: return "livephoto"
        }
    }
    var defaultFrameRate: Int { self == .keyframes ? 2 : 30 }
    var frameRates: [Int] {
        switch self {
        case .keyframes: return [1, 2, 4]
        case .video: return [15, 30, 60]
        case .gif: return GIFRecordingSettings.frameRates
        }
    }
    var maximumDimensionRange: ClosedRange<Int> {
        switch self {
        case .keyframes: return 1...16_384
        case .video: return 2...4_096
        case .gif: return 1...1_920
        }
    }
}
