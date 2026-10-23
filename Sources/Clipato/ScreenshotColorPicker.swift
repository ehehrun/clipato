import CoreGraphics
import Foundation

enum ScreenshotColorFormat: String, CaseIterable, Identifiable {
    case hex
    case rgb
    case hsl

    static let defaultsKey = "screenshotColorFormat"

    var id: Self { self }
    var title: String { rawValue.uppercased() }
    var next: Self {
        switch self {
        case .hex: .rgb
        case .rgb: .hsl
        case .hsl: .hex
        }
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .hex
    }
}

enum ScreenPixelColorError: Error, Equatable {
    case outsideImage
    case samplingFailed
}

struct ScreenPixelColor: Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8

    private static let formattingLocale = Locale(identifier: "en_US_POSIX")

    static func sample(image: CGImage, x: Int, y: Int) throws -> Self {
        try ScreenPixelColorSampler().sample(image: image, x: x, y: y)
    }

    func formatted(_ format: ScreenshotColorFormat) -> String {
        switch format {
        case .hex:
            return String(format: "#%02X%02X%02X", Int(r), Int(g), Int(b))
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let red = Double(r) / 255
            let green = Double(g) / 255
            let blue = Double(b) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let lightness = (maximum + minimum) / 2
            var hue = 0.0
            var saturation = 0.0
            if delta > 0 {
                saturation = delta / (1 - abs(2 * lightness - 1))
                switch maximum {
                case red: hue = (green - blue) / delta
                case green: hue = (blue - red) / delta + 2
                default: hue = (red - green) / delta + 4
                }
                hue *= 60
                if hue < 0 { hue += 360 }
            }
            let roundedHue = (hue * 10).rounded() / 10
            return "hsl(\(Self.decimal(roundedHue == 360 ? 0 : roundedHue)), \(Self.decimal(saturation * 100))%, \(Self.decimal(lightness * 100))%)"
        }
    }

    private static func decimal(_ value: Double) -> String {
        let text = String(format: "%.1f", locale: formattingLocale, value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

final class ScreenPixelColorSampler {
    private let context: CGContext

    init() throws {
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                        CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenPixelColorError.samplingFailed
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        self.context = context
    }

    func sample(image: CGImage, x: Int, y: Int) throws -> ScreenPixelColor {
        guard x >= 0, y >= 0, x < image.width, y < image.height else {
            throw ScreenPixelColorError.outsideImage
        }
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            throw ScreenPixelColorError.samplingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgba = context.data!.assumingMemoryBound(to: UInt8.self)
        let alpha = Int(rgba[3])
        guard alpha > 0 else { return ScreenPixelColor(r: 0, g: 0, b: 0) }
        func component(_ byte: UInt8) -> UInt8 { UInt8((Int(byte) * 255 + alpha / 2) / alpha) }
        return ScreenPixelColor(r: component(rgba[0]), g: component(rgba[1]), b: component(rgba[2]))
    }
}
