import CoreGraphics
import Foundation

public struct ImageGridOptions: Equatable, Sendable {
    public var divisions: Int
    public var tileSize: Int
    public var gap: Int
    public var crop: CGRect?

    public init(divisions: Int = 3, tileSize: Int = 1080, gap: Int = 0, crop: CGRect? = nil) {
        self.divisions = divisions
        self.tileSize = tileSize
        self.gap = gap
        self.crop = crop
    }
}

public enum ImageGridError: Error, LocalizedError, Equatable, Sendable {
    case invalidDivisions(Int)
    case invalidTileSize(Int)
    case invalidGap(Int)
    case requiresCrop
    case invalidCrop
    case sourceTooSmall(requiredSide: Int)
    case invalidIndex(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDivisions(let count): return "An image grid must have 2 or 3 divisions: \(count)."
        case .invalidTileSize(let size): return "Each tile must be from 1 to 4096 pixels square: \(size)."
        case .invalidGap(let gap): return "The image grid gap must be a nonnegative number of source pixels: \(gap)."
        case .requiresCrop: return "Choose a square crop before splitting the image grid."
        case .invalidCrop: return "The image grid crop must be an integer square inside the source image."
        case .sourceTooSmall(let side): return "The source crop must be at least \(side) × \(side) pixels."
        case .invalidIndex(let index): return "The image grid tile index is out of range: \(index)."
        }
    }
}

public enum ImageGridStep {
    public static let minimumTileSize = 1

    public static func sourceSide(options: ImageGridOptions) throws -> Int {
        try Task.checkCancellation()
        guard options.divisions == 2 || options.divisions == 3 else {
            throw ImageGridError.invalidDivisions(options.divisions)
        }
        guard (minimumTileSize...4096).contains(options.tileSize) else {
            throw ImageGridError.invalidTileSize(options.tileSize)
        }
        guard options.gap >= 0 else { throw ImageGridError.invalidGap(options.gap) }
        let (gaps, gapOverflow) = options.gap.multipliedReportingOverflow(by: options.divisions - 1)
        let (side, sideOverflow) = (options.divisions * options.tileSize).addingReportingOverflow(gaps)
        guard !gapOverflow, !sideOverflow else { throw ImageGridError.invalidGap(options.gap) }
        return side
    }

    public static func sourceRects(width: Int, height: Int, options: ImageGridOptions) throws -> [CGRect] {
        let requiredSide = try sourceSide(options: options)
        guard width > 0, height > 0, width <= ImageResizeStep.maximumDimension,
              height <= ImageResizeStep.maximumDimension else {
            throw ImageProcessingError.invalidDimensions(width: width, height: height)
        }
        guard width * height <= ImageResizeStep.maximumPixels else {
            throw ImageProcessingError.canvasTooLarge(width: width, height: height)
        }

        let crop: CGRect
        if let selected = options.crop {
            guard selected.minX.isFinite, selected.minY.isFinite, selected.width.isFinite,
                  selected.height.isFinite, selected.width > 0, selected.width == selected.height,
                  selected.minX >= 0, selected.minY >= 0,
                  selected.maxX <= CGFloat(width), selected.maxY <= CGFloat(height),
                  selected.minX.rounded(.down) == selected.minX,
                  selected.minY.rounded(.down) == selected.minY,
                  selected.width.rounded(.down) == selected.width else {
                throw ImageGridError.invalidCrop
            }
            crop = selected
        } else {
            guard width == height else { throw ImageGridError.requiresCrop }
            crop = CGRect(x: 0, y: 0, width: width, height: height)
        }

        let side = Int(crop.width)
        guard side >= requiredSide else { throw ImageGridError.sourceTooSmall(requiredSide: requiredSide) }
        let contentSide = side - options.gap * (options.divisions - 1)
        let tileSide = CGFloat(contentSide) / CGFloat(options.divisions)
        let stride = tileSide + CGFloat(options.gap)
        return (0..<(options.divisions * options.divisions)).map { index in
            CGRect(x: crop.minX + CGFloat(index % options.divisions) * stride,
                   y: crop.minY + CGFloat(index / options.divisions) * stride,
                   width: tileSide, height: tileSide)
        }
    }

    public static func execute(image: CGImage, options: ImageGridOptions, index: Int) throws -> CGImage {
        let rects = try sourceRects(width: image.width, height: image.height, options: options)
        guard rects.indices.contains(index) else { throw ImageGridError.invalidIndex(index) }
        try Task.checkCancellation()
        let size = options.tileSize
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw ImageProcessingError.allocationFailed
        }
        let rect = rects[index]
        let scale = CGFloat(size) / rect.width
        context.interpolationQuality = .high
        // Source rectangles use a top-left origin; Quartz draws images from the bottom left.
        context.draw(image, in: CGRect(x: -rect.minX * scale, y: -(CGFloat(image.height) - rect.maxY) * scale,
            width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        try Task.checkCancellation()
        guard let tile = context.makeImage() else { throw ImageProcessingError.allocationFailed }
        return tile
    }
}
