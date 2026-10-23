import SwiftUI

struct SurfaceBorder: View {
    var color: Color = Palette.line
    let cornerRadius: CGFloat
    var lineWidth: CGFloat = 0.5
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            Self.path(in: geometry.frame(in: .global), cornerRadius: cornerRadius,
                      lineWidth: lineWidth, displayScale: displayScale)
                .fill(color)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func path(in frame: CGRect, cornerRadius: CGFloat, lineWidth: CGFloat, displayScale: CGFloat) -> Path {
        let width = max(1, (lineWidth * displayScale).rounded(.up)) / displayScale
        // Keep the entire outline on physical pixel boundaries inside the clipping rectangle.
        let left = (frame.minX * displayScale).rounded(.up) / displayScale
        let top = (frame.minY * displayScale).rounded(.up) / displayScale
        let right = (frame.maxX * displayScale).rounded(.down) / displayScale
        let bottom = (frame.maxY * displayScale).rounded(.down) / displayScale
        guard right - left > width, bottom - top > width else { return Path() }
        let rect = CGRect(x: left - frame.minX, y: top - frame.minY,
                          width: right - left, height: bottom - top)
        return RoundedRectangle(cornerRadius: cornerRadius)
            .inset(by: width / 2)
            .path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: width))
    }
}
