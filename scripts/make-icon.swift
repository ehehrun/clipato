import AppKit
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("用法：swift scripts/make-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
      original.width == original.height, original.width >= 1024 else {
    fputs("Resources/AppIcon.png 必须为至少 1024 × 1024 的正方形图像。\n", stderr)
    exit(1)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(original, in: CGRect(x: 0, y: 0, width: size, height: size))
    let image = context.makeImage()!
    let entries: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64), ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    for (name, pixels) in entries where pixels == size {
        let url = destination.appendingPathComponent(name)
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        if !CGImageDestinationFinalize(output) { throw CocoaError(.fileWriteUnknown) }
    }
}
