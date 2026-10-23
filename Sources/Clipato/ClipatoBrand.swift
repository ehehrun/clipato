import AppKit

@MainActor
enum ClipatoBrand {
    static let mark: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: bounds.width / 18, y: bounds.height / 18)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineJoin(.round)
            context.setLineWidth(2)

            let rear = CGMutablePath()
            rear.move(to: CGPoint(x: 5.5, y: 6))
            rear.addLine(to: CGPoint(x: 5.5, y: 2))
            rear.addLine(to: CGPoint(x: 16, y: 2))
            rear.addLine(to: CGPoint(x: 16, y: 12.5))
            rear.addLine(to: CGPoint(x: 12.5, y: 12.5))
            context.addPath(rear)
            context.strokePath()

            let front = CGMutablePath()
            front.move(to: CGPoint(x: 12.5, y: 9))
            front.addLine(to: CGPoint(x: 12.5, y: 6))
            front.addLine(to: CGPoint(x: 2, y: 6))
            front.addLine(to: CGPoint(x: 2, y: 16))
            front.addLine(to: CGPoint(x: 12.5, y: 16))
            front.addLine(to: CGPoint(x: 12.5, y: 12.5))

            // Separate the overlapping frames when both use the menu bar's single tint.
            context.setBlendMode(.clear)
            context.setLineCap(.round)
            context.setLineWidth(4)
            context.addPath(front)
            context.strokePath()
            context.setBlendMode(.normal)
            context.setLineCap(.butt)
            context.setLineWidth(2)
            context.addPath(front)
            context.strokePath()
            context.endTransparencyLayer()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
