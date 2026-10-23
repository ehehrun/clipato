import CoreGraphics
import Foundation

public struct CollageSettings {
    public enum Mode: String, CaseIterable, Sendable {
        case grid
        case flow
    }

    public var mode: Mode
    public var columns: Int
    public var rows: Int
    public var scale: Double
    public var maxWidth: Int
    public var maxHeight: Int
    public var spacing: Int
    public var background: CGColor

    public init(
        mode: Mode = .grid,
        columns: Int = 3,
        rows: Int = 3,
        scale: Double = 1,
        maxWidth: Int = 1_600,
        maxHeight: Int = 1_200,
        spacing: Int = 12,
        background: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    ) {
        self.mode = mode
        self.columns = columns
        self.rows = rows
        self.scale = scale
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.spacing = spacing
        self.background = background
    }
}

public struct CollagePlacement: Equatable {
    public let imageIndex: Int
    public var frame: CGRect

    public init(imageIndex: Int, frame: CGRect) {
        self.imageIndex = imageIndex
        self.frame = frame
    }
}

public enum CollageError: Error, LocalizedError {
    case emptySelection
    case invalidSetting(String)
    case insufficientGrid(capacity: Int, count: Int)
    case canvasTooLarge(width: Int, height: Int)
    case contextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "请至少选择一张图片。"
        case .invalidSetting(let message):
            return message
        case .insufficientGrid(let capacity, let count):
            return "当前网格只有 \(capacity) 个位置，无法放下 \(count) 张图片。请增加行数或列数。"
        case .canvasTooLarge(let width, let height):
            return "画布尺寸 \(width) × \(height) 超过限制。请降低缩放比例、元素最大宽高或行列数。"
        case .contextCreationFailed:
            return "无法创建拼图画布。"
        }
    }
}

public enum CollageRenderer {
    public static let maximumCanvasPixels = 64_000_000
    public static let maximumCanvasDimension = 32_768

    public static func layout(images: [CGImage], settings: CollageSettings) throws -> (size: CGSize, placements: [CollagePlacement]) {
        guard !images.isEmpty else { throw CollageError.emptySelection }
        guard images.count <= 4_096 else {
            throw CollageError.invalidSetting("一次最多拼接 4096 张图片。")
        }
        guard (1...64).contains(settings.columns), (1...64).contains(settings.rows) else {
            throw CollageError.invalidSetting("行数和列数必须介于 1 到 64。")
        }
        guard settings.scale.isFinite, (0.05...4).contains(settings.scale) else {
            throw CollageError.invalidSetting("缩放比例必须介于 5% 到 400%。")
        }
        guard (1...8_192).contains(settings.maxWidth), (1...8_192).contains(settings.maxHeight) else {
            throw CollageError.invalidSetting("元素最大宽高必须介于 1 到 8192 像素。")
        }
        guard (0...512).contains(settings.spacing) else {
            throw CollageError.invalidSetting("间距必须介于 0 到 512 像素。")
        }
        if settings.mode == .grid, settings.columns * settings.rows < images.count {
            throw CollageError.insufficientGrid(capacity: settings.columns * settings.rows, count: images.count)
        }

        let sizes = images.map { image -> CGSize in
            let factor = min(
                settings.scale,
                Double(settings.maxWidth) / Double(image.width),
                Double(settings.maxHeight) / Double(image.height)
            )
            return CGSize(
                width: max(1, Int((Double(image.width) * factor).rounded(.down))),
                height: max(1, Int((Double(image.height) * factor).rounded(.down)))
            )
        }
        let cellWidth = Int(sizes.map(\.width).max()!)
        let cellHeight = Int(sizes.map(\.height).max()!)
        let gap = settings.spacing
        var rectangles: [CGRect] = []
        let width: Int
        let height: Int

        switch settings.mode {
        case .grid:
            width = cellWidth * settings.columns + gap * (settings.columns - 1)
            height = cellHeight * settings.rows + gap * (settings.rows - 1)
            rectangles = sizes.enumerated().map { index, size in
                CGRect(
                    x: CGFloat((index % settings.columns) * (cellWidth + gap)) + (CGFloat(cellWidth) - size.width) / 2,
                    y: CGFloat((index / settings.columns) * (cellHeight + gap)) + (CGFloat(cellHeight) - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
            }
        case .flow:
            // columns sets the target row width; actual element sizes determine the packing.
            let rowWidth = cellWidth * settings.columns + gap * (settings.columns - 1)
            var x = 0
            var y = 0
            var rowHeight = 0
            var usedWidth = 0
            for size in sizes {
                let itemWidth = Int(size.width)
                let itemHeight = Int(size.height)
                if x > 0, x + itemWidth > rowWidth {
                    x = 0
                    y += rowHeight + gap
                    rowHeight = 0
                }
                rectangles.append(CGRect(x: x, y: y, width: itemWidth, height: itemHeight))
                usedWidth = max(usedWidth, x + itemWidth)
                rowHeight = max(rowHeight, itemHeight)
                x += itemWidth + gap
            }
            width = usedWidth
            height = y + rowHeight
        }

        let size = CGSize(width: width, height: height)
        try validateCanvas(size: size)
        return (size, rectangles.enumerated().map { CollagePlacement(imageIndex: $0.offset, frame: $0.element) })
    }

    public static func render(images: [CGImage], settings: CollageSettings) throws -> CGImage {
        let layout = try layout(images: images, settings: settings)
        return try draw(
            images: images,
            placements: layout.placements,
            bounds: CGRect(origin: .zero, size: layout.size),
            background: settings.background
        )
    }

    public static func bounds(for placements: [CollagePlacement]) throws -> CGRect {
        guard !placements.isEmpty else { throw CollageError.emptySelection }
        guard placements.count <= 4_096 else {
            throw CollageError.invalidSetting("一次最多拼接 4096 张图片。")
        }
        var bounds = CGRect.null
        var imageIndices = Set<Int>()
        for placement in placements {
            guard placement.imageIndex >= 0, imageIndices.insert(placement.imageIndex).inserted else {
                throw CollageError.invalidSetting("拼图图片索引必须有效且不能重复。")
            }
            let frame = placement.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0,
                  frame.maxX.isFinite, frame.maxY.isFinite,
                  frame.maxX > frame.minX, frame.maxY > frame.minY else {
                throw CollageError.invalidSetting("图片位置必须为有限坐标，宽高必须大于零。")
            }
            bounds = bounds.union(frame)
        }
        bounds = bounds.integral
        try validateCanvas(size: bounds.size)
        return bounds
    }

    public static func render(images: [CGImage], placements: [CollagePlacement], background: CGColor) throws -> CGImage {
        guard images.count <= 4_096 else {
            throw CollageError.invalidSetting("一次最多拼接 4096 张图片。")
        }
        let bounds = try bounds(for: placements)
        guard placements.allSatisfy({ images.indices.contains($0.imageIndex) }) else {
            throw CollageError.invalidSetting("拼图图片索引超出所选图片范围。")
        }
        return try draw(images: images, placements: placements, bounds: bounds, background: background)
    }

    private static func validateCanvas(size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width < CGFloat(Int.max), size.height < CGFloat(Int.max) else {
            throw CollageError.invalidSetting("拼图画布尺寸超出可处理范围。")
        }
        let width = Int(size.width)
        let height = Int(size.height)
        guard width <= maximumCanvasDimension,
              height <= maximumCanvasDimension,
              width * height <= maximumCanvasPixels else {
            throw CollageError.canvasTooLarge(width: width, height: height)
        }
    }

    private static func draw(images: [CGImage], placements: [CollagePlacement], bounds: CGRect, background: CGColor) throws -> CGImage {
        let width = Int(bounds.width)
        let height = Int(bounds.height)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw CollageError.contextCreationFailed
        }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for placement in placements {
            let rectangle = placement.frame
            let destination = CGRect(
                x: rectangle.minX - bounds.minX,
                y: bounds.maxY - rectangle.maxY,
                width: rectangle.width,
                height: rectangle.height
            )
            context.draw(images[placement.imageIndex], in: destination)
        }
        guard let image = context.makeImage() else { throw CollageError.contextCreationFailed }
        return image
    }
}
