import AppKit

final class MosaicRenderer {
    private let image: CGImage
    private let pixelated = NSCache<NSNumber, CGImage>()

    init(image: CGImage, crop: CGRect? = nil) throws {
        if let crop {
            guard crop.width > 0, crop.height > 0,
                  CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(crop),
                  let cropped = image.cropping(to: crop) else { throw AnnotationRenderError.invalidCrop }
            self.image = cropped
        } else {
            self.image = image
        }
        pixelated.countLimit = 8
        pixelated.totalCostLimit = 8 * 1024 * 1024
    }

    // The context and mask use top-left image pixels, independent of display scale.
    func draw(_ annotation: ImageAnnotation, in context: CGContext) throws {
        guard annotation.tool == .mosaic else {
            annotation.stroke(in: context)
            return
        }
        guard annotation.isDrawable else { return }
        let preview = try pixelatedImage(blockSize: annotation.mosaicSize)
        context.saveGState()
        context.addPath(annotation.mosaicMask)
        context.clip()
        context.interpolationQuality = .none
        // Replace alpha as well as color; source-over would leave original details in transparent images.
        context.setBlendMode(.copy)
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(preview, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
    }

    private func pixelatedImage(blockSize: CGFloat) throws -> CGImage {
        let key = NSNumber(value: Double(blockSize))
        if let cached = pixelated.object(forKey: key) { return cached }
        let width = Int(ceil(CGFloat(image.width) / blockSize))
        let height = Int(ceil(CGFloat(image.height) / blockSize))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AnnotationRenderError.bitmapUnavailable
        }
        // Quartz downsamples the original once per block size; each brush update only clips and draws this small bitmap.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw AnnotationRenderError.bitmapUnavailable }
        pixelated.setObject(result, forKey: key, cost: result.bytesPerRow * result.height)
        return result
    }
}
