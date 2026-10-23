import AppKit

enum AnnotationTool: String, CaseIterable, Identifiable {
    case rectangle, arrow, pen, text, mosaic
    var id: Self { self }
    var title: String {
        switch self {
        case .rectangle: return L("矩形")
        case .arrow: return L("箭头")
        case .pen: return L("画笔")
        case .text: return L("文字")
        case .mosaic: return L("马赛克")
        }
    }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        }
    }

    var image: NSImage {
        switch self {
        case .text: return Self.textImage
        case .mosaic: return Self.mosaicImage
        default: return NSImage(systemSymbolName: symbol, accessibilityDescription: title)!
        }
    }

    private static let textImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(rect: CGRect(x: 2, y: 12, width: 12, height: 2)).fill()
            NSBezierPath(rect: CGRect(x: 7, y: 2, width: 2, height: 12)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    private static let mosaicImage: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            defer { context.restoreGState() }
            context.setShouldAntialias(false)
            let opacity: [CGFloat] = [1, 0.35, 0.75, 0.55,
                                      0.55, 1, 0.25, 0.85,
                                      0.85, 0.55, 1, 0.35,
                                      0.35, 0.8, 0.55, 1]
            for (index, alpha) in opacity.enumerated() {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(rect: CGRect(x: (index % 4) * 4, y: (index / 4) * 4, width: 4, height: 4)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

enum MosaicShape: String, CaseIterable, Identifiable {
    case rectangle, brush
    var id: Self { self }
    var title: String { self == .rectangle ? L("矩形") : L("涂抹") }
}

struct ImageAnnotation: Equatable {
    let tool: AnnotationTool
    var points: [CGPoint]
    let color: NSColor
    let width: CGFloat
    var text = ""
    var fontSize: CGFloat = 24
    var textWidth: CGFloat = 0
    var mosaicShape: MosaicShape = .brush
    var mosaicSize: CGFloat = 16

    var isDrawable: Bool {
        guard let first = points.first, let last = points.last else { return false }
        switch tool {
        case .text: return !text.isEmpty
        case .mosaic where mosaicShape == .brush: return width > 0
        case .rectangle, .mosaic: return first.x != last.x && first.y != last.y
        case .arrow, .pen: return points.contains { $0 != first }
        }
    }

    var path: CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch tool {
        case .rectangle:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(max(width * 5, 12), hypot(last.x - first.x, last.y - first.y) * 0.4)
            path.move(to: CGPoint(x: last.x - head * cos(angle - .pi / 6), y: last.y - head * sin(angle - .pi / 6)))
            path.addLine(to: last)
            path.addLine(to: CGPoint(x: last.x - head * cos(angle + .pi / 6), y: last.y - head * sin(angle + .pi / 6)))
        case .text:
            break
        case .mosaic:
            return mosaicMask
        case .pen:
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    var mosaicMask: CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        if mosaicShape == .rectangle {
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
            return path
        }
        if !points.contains(where: { $0 != first }) {
            path.addEllipse(in: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width))
            return path
        }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color]
    }

    private func textLayout() -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(string: text, attributes: textAttributes)
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return (storage, layout, container)
    }

    var textBounds: CGRect {
        guard tool == .text, !text.isEmpty else { return .null }
        let (storage, layout, container) = textLayout()
        return withExtendedLifetime(storage) {
            layout.usedRect(for: container).offsetBy(dx: points[0].x, dy: points[0].y)
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat, textBounds: CGRect) -> Bool {
        if tool == .mosaic { return false }
        if tool == .text { return textBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
        // Keep empty shape interiors available for drawing another annotation.
        return path.copy(strokingWithWidth: width + tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }

    func selectionBounds(textBounds: CGRect) -> CGRect {
        if tool == .text { return textBounds }
        if tool == .mosaic { return .null }
        return path.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
    }

    func movedText(by delta: CGPoint, within bounds: CGRect, textBounds: CGRect) -> ImageAnnotation {
        let x = min(max(textBounds.minX + delta.x, bounds.minX), max(bounds.minX, bounds.maxX - textBounds.width))
        let y = min(max(textBounds.minY + delta.y, bounds.minY), max(bounds.minY, bounds.maxY - textBounds.height))
        var moved = self
        moved.points[0].x += x - textBounds.minX
        moved.points[0].y += y - textBounds.minY
        return moved
    }

    func stroke(in context: CGContext) {
        if tool == .text {
            guard let origin = points.first, !text.isEmpty else { return }
            let (storage, layout, container) = textLayout()
            withExtendedLifetime(storage) {
                let range = layout.glyphRange(for: container)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                NSGraphicsContext.restoreGraphicsState()
            }
            return
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }
}

enum AnnotationChange {
    case add(ImageAnnotation)
    case replace(index: Int, before: ImageAnnotation, after: ImageAnnotation)
    case remove(index: Int, annotation: ImageAnnotation)

    func apply(to annotations: inout [ImageAnnotation]) {
        switch self {
        case .add(let annotation): annotations.append(annotation)
        case .replace(let index, _, let after): annotations[index] = after
        case .remove(let index, _): annotations.remove(at: index)
        }
    }

    func undo(in annotations: inout [ImageAnnotation]) {
        switch self {
        case .add: annotations.removeLast()
        case .replace(let index, let before, _): annotations[index] = before
        case .remove(let index, let annotation): annotations.insert(annotation, at: index)
        }
    }
}

func renderAnnotatedImage(_ image: CGImage, crop: CGRect? = nil, annotations: [ImageAnnotation]) throws -> CGImage {
    if crop == nil && annotations.isEmpty { return image }
    let rect = crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard rect.width > 0, rect.height > 0,
          CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rect),
          let cropped = image.cropping(to: rect) else { throw AnnotationRenderError.invalidCrop }
    // Detach from the full-screen bitmap; only the selected pixels stay in the vault or pinned panel.
    guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw AnnotationRenderError.bitmapUnavailable
    }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    context.translateBy(x: 0, y: CGFloat(cropped.height))
    context.scaleBy(x: 1, y: -1)
    let renderer = try MosaicRenderer(image: cropped)
    for annotation in annotations { try renderer.draw(annotation, in: context) }
    guard let result = context.makeImage() else { throw AnnotationRenderError.bitmapUnavailable }
    return result
}

enum AnnotationRenderError: LocalizedError {
    case invalidCrop, bitmapUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidCrop: return L("无法裁切所选区域，请重新截图。")
        case .bitmapUnavailable: return L("内存不足，无法生成标注图片。")
        }
    }
}
