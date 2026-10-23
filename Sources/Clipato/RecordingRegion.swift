import CoreGraphics
import ScreenCaptureKit

struct RecordingRegion: Equatable {
    let displayID: CGDirectDisplayID
    // Display-local logical points, with the origin at the top-left corner.
    let rect: CGRect

    func validate(displayID: CGDirectDisplayID, displaySize: CGSize) throws {
        guard self.displayID == displayID else { throw RecordingRegionError.displayMismatch }
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else {
            throw RecordingRegionError.invalidDisplay
        }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else {
            throw RecordingRegionError.invalidRect
        }
        guard rect.origin.x >= 0, rect.origin.y >= 0,
              rect.maxX.isFinite, rect.maxY.isFinite,
              rect.maxX <= displaySize.width, rect.maxY <= displaySize.height else {
            throw RecordingRegionError.outsideDisplay
        }
    }

    func appKitFrame(screenFrame: CGRect) throws -> CGRect {
        try validate(displayID: displayID, displaySize: screenFrame.size)
        guard screenFrame.origin.x.isFinite, screenFrame.origin.y.isFinite,
              screenFrame.maxX.isFinite, screenFrame.maxY.isFinite else {
            throw RecordingRegionError.invalidDisplay
        }
        return CGRect(x: screenFrame.minX + rect.minX,
                      y: screenFrame.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    func configuration(
        displayID: CGDirectDisplayID, contentRect: CGRect,
        pointPixelScale: CGFloat, maxDimension: Int
    ) throws -> SCStreamConfiguration {
        try validate(displayID: displayID, displaySize: contentRect.size)
        guard pointPixelScale.isFinite, pointPixelScale > 0 else { throw RecordingRegionError.invalidPixelScale }
        guard maxDimension > 0 else { throw RecordingRegionError.invalidMaximumDimension }
        let nativeWidth = rect.width * pointPixelScale
        let nativeHeight = rect.height * pointPixelScale
        guard nativeWidth.isFinite, nativeHeight.isFinite else { throw RecordingRegionError.invalidPixelScale }
        let scale = min(1, CGFloat(maxDimension) / max(nativeWidth, nativeHeight))
        let width = (nativeWidth * scale).rounded()
        let height = (nativeHeight * scale).rounded()
        guard width < CGFloat(Int.max), height < CGFloat(Int.max) else { throw RecordingRegionError.invalidMaximumDimension }
        let configuration = SCStreamConfiguration()
        // ScreenCaptureKit sourceRect is in points; width/height are output pixels.
        configuration.sourceRect = rect
        configuration.width = max(1, Int(width))
        configuration.height = max(1, Int(height))
        return configuration
    }
}

private enum RecordingRegionError: LocalizedError {
    case displayMismatch, invalidDisplay, invalidRect, outsideDisplay, invalidPixelScale, invalidMaximumDimension

    var errorDescription: String? {
        switch self {
        case .displayMismatch: return L("录屏区域与所选显示器不匹配，请重新框选。")
        case .invalidDisplay: return L("所选显示器的逻辑尺寸无效，请重新选择屏幕。")
        case .invalidRect: return L("录屏区域必须使用有限坐标，宽度和高度须大于 0。")
        case .outsideDisplay: return L("录屏区域超出所选显示器，请在单个屏幕内框选。")
        case .invalidPixelScale: return L("所选显示器的像素比例无效，无法确定录屏尺寸。")
        case .invalidMaximumDimension: return L("录屏最大尺寸无效，无法生成输出画面。")
        }
    }
}
