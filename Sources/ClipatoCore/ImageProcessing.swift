import CoreGraphics
import CWebP
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let maximumWebPDimension = 16_383

public enum ImageOutputFormat: String, CaseIterable, Equatable, Sendable {
    case png, jpeg, webp
}

public struct ImageResizeOptions: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case fit, pad, crop
    }

    public var width: Int
    public var height: Int
    public var mode: Mode

    public init(width: Int, height: Int, mode: Mode = .fit) {
        self.width = width
        self.height = height
        self.mode = mode
    }
}

public struct CompressedImage: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let quality: Int

    public init(data: Data, width: Int, height: Int, quality: Int) {
        self.data = data
        self.width = width
        self.height = height
        self.quality = quality
    }
}

public enum ImageProcessingError: Error, LocalizedError, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case invalidWebPDimensions(width: Int, height: Int)
    case canvasTooLarge(width: Int, height: Int)
    case invalidQuality(Int)
    case invalidTargetBytes(Int)
    case unreadableImage(URL)
    case allocationFailed
    case encodingFailed(ImageOutputFormat)
    case targetUnreachable(targetBytes: Int, smallestBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let width, let height):
            return "Image dimensions must be between 1 and 32768 pixels: \(width) × \(height)."
        case .invalidWebPDimensions(let width, let height):
            return "WebP dimensions cannot exceed 16383 pixels: \(width) × \(height)."
        case .canvasTooLarge(let width, let height):
            return "The image exceeds 64 million pixels: \(width) × \(height)."
        case .invalidQuality(let quality): return "Image quality must be from 1 to 100: \(quality)."
        case .invalidTargetBytes(let bytes): return "The target file size must be positive: \(bytes)."
        case .unreadableImage(let url): return "Cannot read image: \(url.path)"
        case .allocationFailed: return "Cannot allocate image processing pixels."
        case .encodingFailed(let format): return "Cannot encode the image as \(format.rawValue)."
        case .targetUnreachable(let target, let smallest):
            return "Cannot meet the \(target)-byte target. The smallest tested image is \(smallest) bytes."
        }
    }
}

public enum ImageResizeStep {
    public static let maximumDimension = 32_768
    public static let maximumPixels = 64_000_000

    public static func execute(image: CGImage, options: ImageResizeOptions) throws -> CGImage {
        try Task.checkCancellation()
        try validateDimensions(width: options.width, height: options.height)
        let sx = Double(options.width) / Double(image.width)
        let sy = Double(options.height) / Double(image.height)
        let scale = options.mode == .crop ? max(sx, sy) : min(sx, sy)
        let width = options.mode == .fit ? max(1, Int((Double(image.width) * scale).rounded(.down))) : options.width
        let height = options.mode == .fit ? max(1, Int((Double(image.height) * scale).rounded(.down))) : options.height
        try validateCanvas(width: width, height: height)
        if options.mode != .pad, width == image.width, height == image.height { return image }
        let context = try imageContext(width: width, height: height)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if options.mode == .pad {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        } else { context.clear(bounds) }
        context.interpolationQuality = .high
        let drawWidth = options.mode == .fit ? Double(width) : Double(image.width) * scale
        let drawHeight = options.mode == .fit ? Double(height) : Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(width) - drawWidth) / 2, y: (Double(height) - drawHeight) / 2,
                                       width: drawWidth, height: drawHeight))
        try Task.checkCancellation()
        guard let output = context.makeImage() else { throw ImageProcessingError.allocationFailed }
        return output
    }
}

public enum ImageFormatStep {
    public static func readImage(at url: URL, maximumDimension: Int? = nil) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetType(source) != nil,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageProcessingError.unreadableImage(url) }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString { try validatePNGEnd(at: url) }
        let limit = maximumDimension ?? max(width, height)
        try validateDimensions(width: limit, height: limit)
        let scale = min(1, Double(limit) / Double(max(width, height)))
        try validateCanvas(width: max(1, Int((Double(width) * scale).rounded(.up))),
                           height: max(1, Int((Double(height) * scale).rounded(.up))))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw ImageProcessingError.unreadableImage(url)
        }
        try validateCanvas(width: image.width, height: image.height)
        try Task.checkCancellation()
        return image
    }

    public static func validatePNGEnd(at url: URL) throws {
        let file = try FileHandle(forReadingFrom: url)
        let size = try file.seekToEnd()
        try file.seek(toOffset: size >= 12 ? size - 12 : 0)
        let trailer = try file.read(upToCount: 12)
        try file.close()
        guard trailer == Data([0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]) else {
            throw ImageProcessingError.unreadableImage(url)
        }
    }

    public static func execute(image: CGImage, format: ImageOutputFormat, quality: Int = 90) throws -> Data {
        try Task.checkCancellation()
        try validateCanvas(width: image.width, height: image.height)
        guard (1...100).contains(quality) else { throw ImageProcessingError.invalidQuality(quality) }
        if format == .webp { return try encodeWebP(image, quality: quality) }
        let data = NSMutableData()
        let type = format == .png ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodingFailed(format)
        }
        let output: CGImage
        let properties: CFDictionary?
        if format == .jpeg {
            let context = try imageContext(width: image.width, height: image.height)
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
            context.draw(image, in: bounds)
            guard let opaque = context.makeImage() else { throw ImageProcessingError.allocationFailed }
            output = opaque
            properties = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100] as CFDictionary
        } else {
            output = image
            properties = nil
        }
        CGImageDestinationAddImage(destination, output, properties)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.encodingFailed(format) }
        try Task.checkCancellation()
        return data as Data
    }

    private static func encodeWebP(_ image: CGImage, quality: Int) throws -> Data {
        guard image.width <= maximumWebPDimension, image.height <= maximumWebPDimension else {
            throw ImageProcessingError.invalidWebPDimensions(width: image.width, height: image.height)
        }
        let context = try imageContext(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            if y.isMultiple(of: 32) { try Task.checkCancellation() }
            let row = pixels.advanced(by: y * context.bytesPerRow)
            for x in 0..<image.width {
                let pixel = row.advanced(by: x * 4)
                let alpha = Int(pixel[3])
                if alpha > 0, alpha < 255 {
                    for channel in 0..<3 { pixel[channel] = UInt8(min(255, (Int(pixel[channel]) * 255 + alpha / 2) / alpha)) }
                }
            }
        }
        var encoded: UnsafeMutablePointer<UInt8>?
        let count = quality == 100
            ? WebPEncodeLosslessRGBA(pixels, Int32(image.width), Int32(image.height), Int32(context.bytesPerRow), &encoded)
            : WebPEncodeRGBA(pixels, Int32(image.width), Int32(image.height), Int32(context.bytesPerRow), Float(quality), &encoded)
        guard count > 0, let encoded else { throw ImageProcessingError.encodingFailed(.webp) }
        let data = Data(bytesNoCopy: encoded, count: count, deallocator: .custom { bytes, _ in WebPFree(bytes) })
        try Task.checkCancellation()
        return data
    }
}

public enum ImageCompressionStep {
    public static func execute(image: CGImage, format: ImageOutputFormat, targetBytes: Int,
                               allowResizing: Bool = true) throws -> CompressedImage {
        try Task.checkCancellation()
        guard targetBytes > 0 else { throw ImageProcessingError.invalidTargetBytes(targetBytes) }
        var current = image
        if format == .webp, allowResizing, image.width > maximumWebPDimension || image.height > maximumWebPDimension {
            current = try ImageResizeStep.execute(image: image, options: .init(width: maximumWebPDimension, height: maximumWebPDimension))
        }
        var smallestBytes = Int.max
        for attempt in 0..<12 {
            try Task.checkCancellation()
            let result = try bestEncoding(image: current, format: format, targetBytes: targetBytes,
                                          minimumQuality: allowResizing ? 55 : 1)
            smallestBytes = min(smallestBytes, result.smallestBytes)
            if let output = result.image { return output }
            guard allowResizing, attempt < 11, current.width > 1 || current.height > 1 else { break }
            let factor = min(0.95, sqrt(Double(targetBytes) / Double(result.smallestBytes)) * 0.95)
            let width = max(1, Int((Double(current.width) * factor).rounded(.down)))
            let height = max(1, Int((Double(current.height) * factor).rounded(.down)))
            current = try ImageResizeStep.execute(image: image, options: .init(width: width, height: height))
        }
        throw ImageProcessingError.targetUnreachable(targetBytes: targetBytes, smallestBytes: smallestBytes)
    }

    private static func bestEncoding(image: CGImage, format: ImageOutputFormat,
                                     targetBytes: Int, minimumQuality: Int) throws -> (image: CompressedImage?, smallestBytes: Int) {
        var smallestBytes: Int
        do {
            let data = try autoreleasepool { try ImageFormatStep.execute(image: image, format: format, quality: 100) }
            smallestBytes = data.count
            if data.count <= targetBytes {
                return (.init(data: data, width: image.width, height: image.height, quality: 100), data.count)
            }
        }
        if format == .png { return (nil, smallestBytes) }
        var best: CompressedImage
        do {
            let data = try autoreleasepool { try ImageFormatStep.execute(image: image, format: format, quality: minimumQuality) }
            smallestBytes = min(smallestBytes, data.count)
            guard data.count <= targetBytes else { return (nil, smallestBytes) }
            best = .init(data: data, width: image.width, height: image.height, quality: minimumQuality)
        }
        var low = minimumQuality + 1
        var high = 99
        while low <= high {
            try Task.checkCancellation()
            let quality = (low + high) / 2
            let data = try autoreleasepool { try ImageFormatStep.execute(image: image, format: format, quality: quality) }
            if data.count <= targetBytes {
                best = .init(data: data, width: image.width, height: image.height, quality: quality)
                low = quality + 1
            } else { high = quality - 1 }
        }
        return (best, min(smallestBytes, best.data.count))
    }
}

private func validateDimensions(width: Int, height: Int) throws {
    guard (1...ImageResizeStep.maximumDimension).contains(width), (1...ImageResizeStep.maximumDimension).contains(height) else {
        throw ImageProcessingError.invalidDimensions(width: width, height: height)
    }
}

private func validateCanvas(width: Int, height: Int) throws {
    try validateDimensions(width: width, height: height)
    guard width * height <= ImageResizeStep.maximumPixels else {
        throw ImageProcessingError.canvasTooLarge(width: width, height: height)
    }
}

private func imageContext(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw ImageProcessingError.allocationFailed
    }
    return context
}
