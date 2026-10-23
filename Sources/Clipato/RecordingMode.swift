import Foundation

enum RecordingMode: String, CaseIterable, Identifiable {
    case keyframes
    case video

    var id: Self { self }
    var title: String { self == .keyframes ? L("关键帧录屏") : L("直接录屏") }
    var toolbarTitle: String { self == .keyframes ? L("关键帧视频") : L("完整视频") }
    var toolbarSymbol: String { self == .keyframes ? "rectangle.stack" : "video" }
    var defaultFrameRate: Int { self == .video ? 30 : 2 }
    var frameRates: [Int] { self == .video ? [15, 30, 60] : [1, 2, 4] }
    var maximumDimensionRange: ClosedRange<Int> { self == .video ? 2...4_096 : 1...16_384 }
}
