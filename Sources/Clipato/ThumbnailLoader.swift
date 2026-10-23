import AppKit
import AVFoundation
import ImageIO

actor ThumbnailLoader {
    private let cache = NSCache<NSURL, CGImage>()
    private var cacheGeneration = 0
    private var decodingVideo = false
    private var waitingVideos: [CheckedContinuation<Void, Never>] = []

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 64
    }

    func image(at url: URL) throws -> CGImage {
        try Task.checkCancellation()
        if let image = cache.object(forKey: url as NSURL) { return image }

        // The actor serializes decoding; cancelled, offscreen requests stop before touching disk.
        let image = try autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 520,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else {
                throw LibraryError.unreadableImage(url.lastPathComponent)
            }
            return image
        }
        try Task.checkCancellation()
        cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    func video(at url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        if let image = cache.object(forKey: url as NSURL) { return image }

        // AVFoundation suspends while decoding; keep those requests serial as cells enter the viewport.
        if decodingVideo {
            await withCheckedContinuation { waitingVideos.append($0) }
        } else {
            decodingVideo = true
        }
        defer {
            if waitingVideos.isEmpty { decodingVideo = false }
            else { waitingVideos.removeFirst().resume() }
        }
        try Task.checkCancellation()
        if let image = cache.object(forKey: url as NSURL) { return image }

        let generation = cacheGeneration
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 520, height: 520)
        generator.appliesPreferredTrackTransform = true
        let image: CGImage
        do {
            image = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await generator.image(at: .zero).image
            } onCancel: {
                generator.cancelAllCGImageGeneration()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        if generation == cacheGeneration {
            cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    func invalidate(_ urls: [URL]) {
        cacheGeneration += 1
        for url in urls { cache.removeObject(forKey: url as NSURL) }
    }

    func clear() {
        cacheGeneration += 1
        cache.removeAllObjects()
    }
}
