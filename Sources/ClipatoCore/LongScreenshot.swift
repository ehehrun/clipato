import CoreGraphics
import Foundation

public struct LongScreenshotJoin: Equatable, Sendable {
    public var overlap: Int
    public var offsetX: Int
    public var confidence: Double?

    public init(overlap: Int, offsetX: Int = 0, confidence: Double? = nil) {
        self.overlap = overlap
        self.offsetX = offsetX
        self.confidence = confidence
    }
}

public enum LongScreenshotAnalysis: Equatable, Sendable {
    case matched(LongScreenshotJoin)
    case duplicate
    case noReliableMatch
}

public enum LongScreenshotError: Error, LocalizedError {
    case invalidSetting(String)
    case imageReadFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSetting(let message): return message
        case .imageReadFailed: return "无法读取长图截图的像素。"
        }
    }
}

public enum LongScreenshot {
    /// Offset is relative to the preceding frame; coordinates remain in source pixels.
    public static func layout(images: [CGImage], joins: [LongScreenshotJoin]) throws -> (size: CGSize, placements: [CollagePlacement]) {
        guard !images.isEmpty, images.count <= 4_096 else {
            throw LongScreenshotError.invalidSetting("长图需要 1 到 4096 张截图。")
        }
        guard joins.count == images.count - 1 else {
            throw LongScreenshotError.invalidSetting("每两张相邻截图必须有一个接缝设置。")
        }
        var placements = [CollagePlacement(imageIndex: 0, frame: CGRect(x: 0, y: 0, width: images[0].width, height: images[0].height))]
        var x = 0
        var y = 0
        for index in 1..<images.count {
            let previous = images[index - 1]
            let image = images[index]
            let join = joins[index - 1]
            x = try checked(x.addingReportingOverflow(join.offsetX))
            y = try checked(y.addingReportingOverflow(previous.height))
            y = try checked(y.subtractingReportingOverflow(join.overlap))
            placements.append(CollagePlacement(imageIndex: index, frame: CGRect(
                x: x, y: y, width: image.width, height: image.height
            )))
        }
        let bounds = try CollageRenderer.bounds(for: placements)
        for index in placements.indices {
            placements[index].frame = placements[index].frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        }
        return (bounds.size, placements)
    }

    public static func moving(joins: [LongScreenshotJoin], imageIndex: Int, dx: Int, dy: Int) throws -> [LongScreenshotJoin] {
        guard (0...joins.count).contains(imageIndex) else {
            throw LongScreenshotError.invalidSetting("移动的截图索引超出范围。")
        }
        guard dx != 0 || dy != 0 else { return joins }
        var result = joins
        if imageIndex > 0 {
            result[imageIndex - 1].offsetX = try checked(result[imageIndex - 1].offsetX.addingReportingOverflow(dx))
            result[imageIndex - 1].overlap = try checked(result[imageIndex - 1].overlap.subtractingReportingOverflow(dy))
            result[imageIndex - 1].confidence = nil
        }
        // Compensate at the outgoing seam so later frames keep their positions.
        if imageIndex < result.count {
            result[imageIndex].offsetX = try checked(result[imageIndex].offsetX.subtractingReportingOverflow(dx))
            result[imageIndex].overlap = try checked(result[imageIndex].overlap.addingReportingOverflow(dy))
            result[imageIndex].confidence = nil
        }
        return result
    }

    public static func render(images: [CGImage], joins: [LongScreenshotJoin]) throws -> CGImage {
        let result = try layout(images: images, joins: joins)
        return try CollageRenderer.render(
            images: images, placements: result.placements,
            background: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
    }

    public static func aligning(joins: [LongScreenshotJoin], analyses: [LongScreenshotAnalysis],
                                joinUnmatched: Bool = false) throws -> [LongScreenshotJoin] {
        guard joins.count == analyses.count else {
            throw LongScreenshotError.invalidSetting("自动对齐结果与接缝数量不一致。")
        }
        var result = joins
        for index in analyses.indices {
            let join: LongScreenshotJoin
            switch analyses[index] {
            case .matched(let match): join = match
            case .noReliableMatch where joinUnmatched: join = LongScreenshotJoin(overlap: 0)
            case .duplicate, .noReliableMatch: continue
            }
            let dx = try checked(join.offsetX.subtractingReportingOverflow(result[index].offsetX))
            let dy = try checked(result[index].overlap.subtractingReportingOverflow(join.overlap))
            if index + 1 < result.count {
                result[index + 1].offsetX = try checked(result[index + 1].offsetX.subtractingReportingOverflow(dx))
                result[index + 1].overlap = try checked(result[index + 1].overlap.addingReportingOverflow(dy))
                result[index + 1].confidence = nil
            }
            result[index] = join
        }
        return result
    }

    /// Maximum overlap bounds the shorter side of the shared rectangle in source pixels.
    public static func analyze(previous: CGImage, next: CGImage, minimumOverlap: Int = 1,
                               maximumOverlap: Int? = nil) throws -> LongScreenshotAnalysis {
        guard minimumOverlap > 0 else {
            throw LongScreenshotError.invalidSetting("最小重叠尺寸必须大于零。")
        }
        if let maximumOverlap {
            guard (0...CollageRenderer.maximumCanvasDimension).contains(maximumOverlap) else {
                throw LongScreenshotError.invalidSetting("重叠容错必须在 0 到 32768 像素之间。")
            }
        }
        for image in [previous, next] {
            guard image.width <= CollageRenderer.maximumCanvasDimension,
                  image.height <= CollageRenderer.maximumCanvasDimension,
                  image.width * image.height <= CollageRenderer.maximumCanvasPixels else {
                throw CollageError.canvasTooLarge(width: image.width, height: image.height)
            }
        }
        if let maximumOverlap, maximumOverlap < minimumOverlap { return .noReliableMatch }
        let a = try AlignmentPixels(previous)
        let b = try AlignmentPixels(next)
        if a.width == b.width, a.height == b.height,
           memcmp(a.bytes, b.bytes, a.width * a.height) == 0,
           try comparePixels(previous, next, dx: 0, dy: 0, ignoringScrollbar: false).exact {
            return .duplicate
        }
        guard min(a.width, b.width) >= minimumOverlap, min(a.height, b.height) >= minimumOverlap else {
            return .noReliableMatch
        }

        if a.width * a.height <= 65_536 / (b.width * b.height) {
            return try exactTranslation(a, b, previous: previous, next: next,
                                        minimumOverlap: minimumOverlap, maximumOverlap: maximumOverlap)
        }
        let af = features(a)
        let bf = features(b)
        guard af.count >= 3, bf.count >= 3 else { return .noReliableMatch }
        let candidates = translations(af, bf, a: a, b: b,
                                      minimumOverlap: minimumOverlap, maximumOverlap: maximumOverlap)
        var matches: [(x: Int, y: Int, error: Double)] = []
        for candidate in candidates {
            // Feature points propose locations; the entire shared content decides
            // whether a translation is valid, including sparse text between margins.
            guard let error = alignmentError(a, b, dx: candidate.x, dy: candidate.y, minimumOverlap: minimumOverlap) else { continue }
            let full = try comparePixels(previous, next, dx: candidate.x, dy: candidate.y, ignoringScrollbar: true, minimumOverlap: minimumOverlap)
            guard full.error <= 6 else { continue }
            matches.append((candidate.x, candidate.y, error))
        }
        matches.sort { $0.error < $1.error }
        guard let best = matches.first else { return .noReliableMatch }
        // Adjacent antialiasing peaks describe one position, but repeated text or
        // patterned backgrounds can support genuinely different translations.
        if matches.dropFirst().contains(where: {
            (abs($0.x - best.x) > 2 || abs($0.y - best.y) > 2) && $0.error <= best.error + 0.04
        }) { return .noReliableMatch }
        return .matched(LongScreenshotJoin(overlap: previous.height - best.y, offsetX: best.x, confidence: 1 - best.error))
    }

    private static func exactTranslation(_ a: AlignmentPixels, _ b: AlignmentPixels, previous: CGImage, next: CGImage,
                                         minimumOverlap: Int, maximumOverlap: Int?) throws -> LongScreenshotAnalysis {
        // The sum of intersection areas over every translation is |a| × |b|.
        // This small-image case therefore has a strict 65,536 pixel-pair bound.
        var match: LongScreenshotJoin?
        for dy in (minimumOverlap - b.height)...(a.height - minimumOverlap) {
            for dx in (minimumOverlap - b.width)...(a.width - minimumOverlap) {
                let x0 = max(0, dx), x1 = min(a.width, dx + b.width)
                let y0 = max(0, dy), y1 = min(a.height, dy + b.height)
                if let maximumOverlap, min(x1 - x0, y1 - y0) > maximumOverlap { continue }
                var minimum = 255
                var maximum = 0
                var equal = true
                rows: for y in y0..<y1 {
                    for x in x0..<x1 {
                        let value = Int(a.bytes[y * a.width + x])
                        if value != Int(b.bytes[(y - dy) * b.width + x - dx]) { equal = false; break rows }
                        minimum = min(minimum, value)
                        maximum = max(maximum, value)
                    }
                }
                guard equal, maximum - minimum >= 32,
                      try comparePixels(previous, next, dx: dx, dy: dy, ignoringScrollbar: false).exact else { continue }
                if match != nil { return .noReliableMatch }
                match = LongScreenshotJoin(overlap: a.height - dy, offsetX: dx, confidence: 1)
            }
        }
        return match.map(LongScreenshotAnalysis.matched) ?? .noReliableMatch
    }

    private struct AlignmentPixels {
        let context: CGContext
        let width: Int
        let height: Int
        var bytes: UnsafeMutablePointer<UInt8> { context.data!.assumingMemoryBound(to: UInt8.self) }
        var contentWidth: Int { width }

        init(_ image: CGImage) throws {
            width = image.width
            height = image.height
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw LongScreenshotError.imageReadFailed
            }
            self.context = context
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    private struct Feature {
        let x: Int
        let y: Int
        let score: Int
        let bits: UInt64
        let mask: UInt64
        var horizontal = false
        var vertical = false
    }

    private static let descriptorPairs: [(Int, Int, Int, Int)] = {
        var state: UInt64 = 0x91e10da5c79e7b1d
        func coordinate() -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int((state >> 32) % 7) - 3
        }
        return (0..<64).map { _ in (coordinate(), coordinate(), coordinate(), coordinate()) }
    }()

    private static func features(_ image: AlignmentPixels) -> [Feature] {
        let width = image.width
        let height = image.height
        let contentWidth = image.contentWidth
        guard contentWidth >= 8, height >= 8 else { return [] }
        let p = image.bytes
        // Keep a bounded, spatially distributed set. Three response rows avoid a
        // second full-size image allocation even for large source screenshots.
        let cell = max(16, Int(sqrt(Double(width * height) / 3_000)))
        let columns = (contentWidth + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        var buckets = [[Feature]](repeating: [], count: columns * rows)
        var responses = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: 3)
        func fill(_ y: Int, _ output: inout [UInt8]) {
            for x in 2..<(contentWidth - 2) {
                let i = y * width + x
                let a = Int(p[i]), b = Int(p[i + 1]), c = Int(p[i + width]), d = Int(p[i + width + 1])
                let horizontalDifference: Int = abs(a - b) + abs(c - d)
                let verticalDifference: Int = abs(a - c) + abs(b - d)
                let response: Int = min(horizontalDifference, verticalDifference) / 2
                output[x] = UInt8(response)
            }
        }
        fill(2, &responses[2])
        fill(3, &responses[0])
        for y in 3..<(height - 3) {
            fill(y + 1, &responses[(y + 1) % 3])
            for x in 3..<(contentWidth - 3) {
                let score = Int(responses[y % 3][x])
                guard score >= 24 else { continue }
                var maximum = true
                neighbors: for oy in -1...1 {
                    for ox in -1...1 where ox != 0 || oy != 0 {
                        let other = Int(responses[(y + oy) % 3][x + ox])
                        if other > score || (other == score && (oy < 0 || (oy == 0 && ox < 0))) {
                            maximum = false
                            break neighbors
                        }
                    }
                }
                guard maximum else { continue }
                let bucket = (y / cell) * columns + x / cell
                if buckets[bucket].count == 6, buckets[bucket].last!.score >= score { continue }
                var bits: UInt64 = 0
                var mask: UInt64 = 0
                for (index, pair) in descriptorPairs.enumerated() {
                    let difference = Int(p[(y + pair.1) * width + x + pair.0]) - Int(p[(y + pair.3) * width + x + pair.2])
                    if abs(difference) >= 12 { mask |= UInt64(1) << index }
                    if difference >= 12 { bits |= UInt64(1) << index }
                }
                guard mask.nonzeroBitCount >= 16 else { continue }
                let feature = Feature(x: x, y: y, score: score, bits: bits, mask: mask)
                let insertion = buckets[bucket].firstIndex(where: { $0.score < score }) ?? buckets[bucket].count
                buckets[bucket].insert(feature, at: insertion)
                if buckets[bucket].count > 6 { buckets[bucket].removeLast() }
            }
        }
        return buckets.flatMap { $0 } + edgeFeatures(image, horizontal: true) + edgeFeatures(image, horizontal: false)
    }

    private static func edgeFeatures(_ image: AlignmentPixels, horizontal: Bool) -> [Feature] {
        // A narrow overlap can contain only a truncated text stroke. Its
        // profile along the boundary survives when a square descriptor does not.
        let length = horizontal ? image.width : image.height
        let lines = horizontal ? image.height : image.width
        guard length >= 20 else { return [] }
        let p = image.bytes
        let band = min(16, lines / 2)
        let edgeLines = Array(0..<band) + Array((lines - band)..<lines)
        let cellWidth = max(16, length / 48)
        let step = horizontal ? 1 : image.width
        var result: [Feature] = []
        for line in edgeLines {
            var buckets = [[Feature]](repeating: [], count: (length + cellWidth - 1) / cellWidth)
            for position in 8..<(length - 8) {
                let x = horizontal ? position : line
                let y = horizontal ? line : position
                let i = y * image.width + x
                let score = abs(Int(p[i + step]) - Int(p[i]))
                guard score >= 32,
                      score > abs(Int(p[i]) - Int(p[i - step])),
                      score >= abs(Int(p[i + step * 2]) - Int(p[i + step])) else { continue }
                let bucket = position / cellWidth
                if buckets[bucket].count == 2, buckets[bucket].last!.score >= score { continue }
                var bits: UInt64 = 0
                var mask: UInt64 = 0
                for index in 0..<64 {
                    let left = (index * 5 + index / 17) % 17 - 8
                    let right = (index * 11 + 3 + index / 13) % 17 - 8
                    let difference = Int(p[i + left * step]) - Int(p[i + right * step])
                    if abs(difference) >= 12 { mask |= UInt64(1) << index }
                    if difference >= 12 { bits |= UInt64(1) << index }
                }
                guard mask.nonzeroBitCount >= 16 else { continue }
                let feature = Feature(x: x, y: y, score: score, bits: bits, mask: mask, horizontal: horizontal, vertical: !horizontal)
                let insertion = buckets[bucket].firstIndex(where: { $0.score < score }) ?? buckets[bucket].count
                buckets[bucket].insert(feature, at: insertion)
                if buckets[bucket].count > 2 { buckets[bucket].removeLast() }
            }
            result.append(contentsOf: buckets.flatMap { $0 })
        }
        return result
    }

    private static func translations(_ a: [Feature], _ b: [Feature], a imageA: AlignmentPixels, b imageB: AlignmentPixels,
                                     minimumOverlap: Int, maximumOverlap: Int?) -> [(x: Int, y: Int)] {
        var index: [UInt32: [Int]] = [:]
        for (position, feature) in a.enumerated() {
            for part in 0..<4 {
                let key = UInt32((feature.horizontal ? 4 : feature.vertical ? 8 : 0) + part) << 16 | UInt32(truncatingIfNeeded: feature.bits >> (part * 16)) & 0xffff
                // A common glyph fragment is not distinctive by itself. Other
                // descriptor segments still contribute without quadratic buckets.
                if index[key, default: []].count <= 64 { index[key, default: []].append(position) }
            }
        }
        var seen = [Int](repeating: -1, count: a.count)
        var votes: [Int64: Int] = [:]
        for (position, feature) in b.enumerated() {
            var close: [(index: Int, distance: Int)] = []
            var best = 9
            for part in 0..<4 {
                let key = UInt32((feature.horizontal ? 4 : feature.vertical ? 8 : 0) + part) << 16 | UInt32(truncatingIfNeeded: feature.bits >> (part * 16)) & 0xffff
                guard let bucket = index[key], bucket.count <= 64 else { continue }
                for ai in bucket where seen[ai] != position {
                    seen[ai] = position
                    let dx = a[ai].x - feature.x
                    let dy = a[ai].y - feature.y
                    let width = min(imageA.width, dx + imageB.width) - max(0, dx)
                    let height = min(imageA.height, dy + imageB.height) - max(0, dy)
                    guard width >= minimumOverlap, height >= minimumOverlap else { continue }
                    if let maximumOverlap, min(width, height) > maximumOverlap { continue }
                    let common = a[ai].mask & feature.mask
                    guard common.nonzeroBitCount >= 16 else { continue }
                    let distance = ((a[ai].bits ^ feature.bits) & common).nonzeroBitCount
                    guard distance <= 6, distance <= best + 1 else { continue }
                    if distance < best { best = distance }
                    close.append((ai, distance))
                }
            }
            for match in close where match.distance <= best + 1 {
                let dx = a[match.index].x - feature.x
                let dy = a[match.index].y - feature.y
                let key = Int64(dx) << 32 | Int64(UInt32(bitPattern: Int32(dy)))
                votes[key, default: 0] += 1
            }
        }
        let ranked = votes.filter { $0.value >= 3 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.prefix(64)
        return ranked.map { (Int($0.key >> 32), Int(Int32(bitPattern: UInt32(truncatingIfNeeded: $0.key)))) }
    }

    private static func alignmentError(_ a: AlignmentPixels, _ b: AlignmentPixels, dx: Int, dy: Int, minimumOverlap: Int) -> Double? {
        let x0 = max(0, dx)
        let y0 = max(0, dy)
        let rawX1 = min(a.width, dx + b.width)
        let x1 = max(x0 + minimumOverlap, min(a.width - min(16, a.width / 64), dx + b.width - min(16, b.width / 64)))
        let y1 = min(a.height, dy + b.height)
        guard rawX1 - x0 >= minimumOverlap, y1 - y0 >= minimumOverlap else { return nil }
        let ap = a.bytes
        let bp = b.bytes
        var difference: Int64 = 0
        var edgeDifference: Int64 = 0
        var edges: Int64 = 0
        var detail = 0
        let count = (x1 - x0) * (y1 - y0)
        let limit = Int64(count * 6)
        for y in y0..<y1 {
            var ai = y * a.width + x0
            var bi = (y - dy) * b.width + x0 - dx
            for x in x0..<x1 {
                let av = Int(ap[ai]), bv = Int(bp[bi])
                difference += Int64(abs(av - bv))
                let ax = x + 1 < x1 ? Int(ap[ai + 1]) - av : 0
                let bx = x + 1 < x1 ? Int(bp[bi + 1]) - bv : 0
                let ay = y + 1 < y1 ? Int(ap[ai + a.width]) - av : 0
                let by = y + 1 < y1 ? Int(bp[bi + b.width]) - bv : 0
                let edge = abs(ax) + abs(ay) + abs(bx) + abs(by)
                edges += Int64(edge)
                edgeDifference += Int64(abs(ax - bx) + abs(ay - by))
                if edge >= 64 { detail += 1 }
                ai += 1
                bi += 1
            }
            if difference > limit { return nil }
        }
        guard detail >= 24, edges > 0 else { return nil }
        let edgeError = Double(edgeDifference) / Double(edges)
        guard edgeError <= 0.18 else { return nil }
        return edgeError + Double(difference) / Double(count) / 255
    }

    private static func comparePixels(_ previous: CGImage, _ next: CGImage, dx: Int, dy: Int, ignoringScrollbar: Bool, minimumOverlap: Int = 1) throws
        -> (error: Double, exact: Bool) {
        let trimA = ignoringScrollbar ? min(16, previous.width / 64) : 0
        let trimB = ignoringScrollbar ? min(16, next.width / 64) : 0
        let x0 = max(0, dx)
        let y0 = max(0, dy)
        let width = max(minimumOverlap, min(previous.width - trimA, dx + next.width - trimB) - x0)
        let height = min(previous.height, dy + next.height) - y0
        let stripeHeight = min(64, height)
        let a = try makeContext(width: width, height: stripeHeight)
        let b = try makeContext(width: width, height: stripeHeight)
        a.setBlendMode(.copy)
        b.setBlendMode(.copy)
        let ap = a.data!.assumingMemoryBound(to: UInt8.self)
        let bp = b.data!.assumingMemoryBound(to: UInt8.self)
        var difference: Int64 = 0
        var count = 0
        var exact = true
        for row in stride(from: 0, to: height, by: stripeHeight) {
            let rows = min(stripeHeight, height - row)
            guard let ac = previous.cropping(to: CGRect(x: x0, y: y0 + row, width: width, height: rows)),
                  let bc = next.cropping(to: CGRect(x: x0 - dx, y: y0 - dy + row, width: width, height: rows)) else {
                throw LongScreenshotError.imageReadFailed
            }
            let rectangle = CGRect(x: 0, y: stripeHeight - rows, width: width, height: rows)
            a.draw(ac, in: rectangle)
            b.draw(bc, in: rectangle)
            for index in stride(from: 0, to: rows * width * 4, by: 4) {
                for channel in 0..<4 {
                    let delta = abs(Int(ap[index + channel]) - Int(bp[index + channel]))
                    if delta != 0 { exact = false }
                    if channel < 3 {
                        difference += Int64(delta)
                        count += 1
                    }
                }
            }
        }
        return (Double(difference) / Double(count), exact)
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { throw LongScreenshotError.imageReadFailed }
        return context
    }

    private static func checked(_ result: (partialValue: Int, overflow: Bool)) throws -> Int {
        guard !result.overflow else {
            throw LongScreenshotError.invalidSetting("图片位置超出可处理的整数范围。")
        }
        return result.partialValue
    }
}
