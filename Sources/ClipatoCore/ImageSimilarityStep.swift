import CoreGraphics
import Foundation
import ImageIO

public struct ImageSimilarityMatch: Sendable {
    public enum Kind: String, Sendable {
        case similar, firstContainsSecond, secondContainsFirst
    }
    public let first: URL
    public let second: URL
    public let kind: Kind
    public let score: Double

    public init(first: URL, second: URL, kind: Kind, score: Double) {
        self.first = first
        self.second = second
        self.kind = kind
        self.score = score
    }
}

public enum ImageSimilarityError: LocalizedError {
    case unreadableImage(URL)
    case pixelAllocation

    public var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): return "Cannot read image: \(url.path)"
        case .pixelAllocation: return "Cannot allocate image comparison pixels."
        }
    }
}

public enum ImageSimilarityStep {
    private static let maximumDimension = 768
    private static let featuresPerLevel = 40
    private static let levelCount = 9

    public static func execute(urls: [URL], progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> [ImageSimilarityMatch] {
        var signatures: [Int: Signature] = [:]
        var descriptors: [Descriptor] = []
        var descriptorIDs: [Descriptor: Int] = [:]
        var occurrences: [[Reference]] = []
        var index: [UInt32: [Int]] = [:]
        var wholeIndex: [UInt64: [Int]] = [:]
        var matches: [ImageSimilarityMatch] = []
        progress(0, urls.count)
        for (position, url) in urls.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let pixels = try Pixels(url: url)
                let signature = try Signature(pixels)
                var proposals: [Int: [Int: Correspondence]] = [:]
                var indexWork = 0
                for (featureIndex, feature) in signature.features.enumerated() {
                    if featureIndex % 32 == 0 { try Task.checkCancellation() }
                    var seen: Set<Int> = []
                    for part in 0..<4 {
                        guard let bucket = index[feature.descriptor.key(part)] else { continue }
                        for descriptorID in bucket where seen.insert(descriptorID).inserted {
                            indexWork += 1
                            if indexWork % 256 == 0 { try Task.checkCancellation() }
                            guard let distance = feature.descriptor.distance(to: descriptors[descriptorID]) else { continue }
                            for reference in occurrences[descriptorID] {
                                indexWork += 1
                                if indexWork % 256 == 0 { try Task.checkCancellation() }
                                let image = Int(reference.image)
                                let previous = signatures[image]!.features[Int(reference.feature)]
                                let match = Correspondence(first: previous, second: feature, distance: distance)
                                if let old = proposals[image]?[featureIndex], old.distance <= distance { continue }
                                proposals[image, default: [:]][featureIndex] = match
                            }
                        }
                    }
                }
                let ranked = proposals.compactMap { image, matches -> (image: Int, strength: Int)? in
                    let strength = candidateStrength(Array(matches.values))
                    return strength >= 4 ? (image, strength) : nil
                }.sorted { $0.strength == $1.strength ? $0.image < $1.image : $0.strength > $1.strength }
                var candidates = Set(ranked.map(\.image))
                for key in signature.wholeKeys {
                    for candidate in wholeIndex[key, default: []] {
                        indexWork += 1
                        if indexWork % 256 == 0 { try Task.checkCancellation() }
                        let old = signatures[candidate]!
                        if abs(Double(old.width) / Double(old.height) / (Double(signature.width) / Double(signature.height)) - 1) < 0.025 {
                            candidates.insert(candidate)
                        }
                    }
                }
                var wholeEquivalent = false
                for candidate in candidates.sorted() where urls[candidate] != url {
                    try Task.checkCancellation()
                    let previous = signatures[candidate]!
                    if let flat = signature.flatColor, previous.flatColor == flat {
                        matches.append(ImageSimilarityMatch(first: urls[candidate], second: url, kind: .similar, score: 1))
                        wholeEquivalent = true
                        continue
                    }
                    let correspondences = Array(proposals[candidate, default: [:]].values).sorted {
                        if $0.distance != $1.distance { return $0.distance < $1.distance }
                        if $0.second.y != $1.second.y { return $0.second.y < $1.second.y }
                        return $0.second.x < $1.second.x
                    }
                    let registration = registration(correspondences, first: previous, second: signature)
                    let sameShape = abs(Double(previous.width) / Double(previous.height) / (Double(signature.width) / Double(signature.height)) - 1) < 0.015
                    guard registration != nil || sameShape else { continue }
                    var transforms: [(Transform, Bool)] = []
                    if let registration { transforms.append((registration, false)) }
                    if sameShape {
                        transforms.append((Transform(scale: Double(previous.width) / Double(signature.width), x: 0, y: 0), true))
                    }
                    let best: (ImageSimilarityMatch.Kind, Double)? = try autoreleasepool {
                        let firstPixels = try Pixels(url: urls[candidate])
                        var best: (ImageSimilarityMatch.Kind, Double)?
                        for (transform, whole) in transforms {
                            var result = verify(firstPixels, pixels, transform: transform)
                            if result == nil, let refined = try refine(firstPixels, pixels, transform: transform) {
                                result = verify(firstPixels, pixels, transform: refined)
                            }
                            if let verified = result {
                                if whole { wholeEquivalent = true }
                                if best == nil || verified.1 > best!.1 { best = verified }
                            }
                        }
                        return best
                    }
                    if let best {
                        matches.append(ImageSimilarityMatch(first: urls[candidate], second: url, kind: best.0, score: best.1))
                    }
                }
                var indexed = false
                for (featureIndex, feature) in signature.features.enumerated() {
                    let descriptor = feature.descriptor
                    let descriptorID: Int
                    if let existing = descriptorIDs[descriptor] {
                        if wholeEquivalent { continue }
                        descriptorID = existing
                    } else {
                        descriptorID = descriptors.count
                        descriptorIDs[descriptor] = descriptorID
                        descriptors.append(descriptor)
                        occurrences.append([])
                        for part in 0..<4 { index[descriptor.key(part), default: []].append(descriptorID) }
                    }
                    occurrences[descriptorID].append(Reference(image: UInt32(position), feature: UInt16(featureIndex)))
                    indexed = true
                }
                if !wholeEquivalent {
                    for key in signature.wholeKeys { wholeIndex[key, default: []].append(position) }
                    indexed = true
                }
                if indexed { signatures[position] = signature }
            }
            progress(position + 1, urls.count)
        }
        try Task.checkCancellation()
        return matches
    }

    private struct Reference: Hashable {
        let image: UInt32
        let feature: UInt16
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        init(url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumDimension
                  ] as CFDictionary) else { throw ImageSimilarityError.unreadableImage(url) }
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { data in
                guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw ImageSimilarityError.pixelAllocation
                }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            rgba = bytes
        }

        func gray() -> Gray {
            var bytes = [UInt8](repeating: 0, count: width * height)
            for index in bytes.indices {
                let i = index * 4
                bytes[index] = UInt8((Int(rgba[i]) * 77 + Int(rgba[i + 1]) * 150 + Int(rgba[i + 2]) * 29) >> 8)
            }
            return Gray(width: width, height: height, bytes: bytes)
        }

        func sample(_ x: Double, _ y: Double, channel: Int) -> Double {
            let x = min(Double(width - 1), max(0, x)), y = min(Double(height - 1), max(0, y))
            let x0 = Int(x), y0 = Int(y)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = x - Double(x0), fy = y - Double(y0)
            let top = Double(rgba[(y0 * width + x0) * 4 + channel]) * (1 - fx) + Double(rgba[(y0 * width + x1) * 4 + channel]) * fx
            let bottom = Double(rgba[(y1 * width + x0) * 4 + channel]) * (1 - fx) + Double(rgba[(y1 * width + x1) * 4 + channel]) * fx
            return top * (1 - fy) + bottom * fy
        }
    }

    private struct Gray {
        let width: Int
        let height: Int
        var bytes: [UInt8]

        func reduced() -> Gray {
            let w = max(1, Int(Double(width) * 0.8)), h = max(1, Int(Double(height) * 0.8))
            var output = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    let sx = Double(x) * Double(width - 1) / Double(max(1, w - 1))
                    let sy = Double(y) * Double(height - 1) / Double(max(1, h - 1))
                    let x0 = Int(sx), y0 = Int(sy)
                    let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
                    let fx = sx - Double(x0), fy = sy - Double(y0)
                    let top = Double(bytes[y0 * width + x0]) * (1 - fx) + Double(bytes[y0 * width + x1]) * fx
                    let bottom = Double(bytes[y1 * width + x0]) * (1 - fx) + Double(bytes[y1 * width + x1]) * fx
                    output[y * w + x] = UInt8(min(255, max(0, top * (1 - fy) + bottom * fy)))
                }
            }
            return Gray(width: w, height: h, bytes: output)
        }

        func smoothed() -> Gray {
            guard width >= 3, height >= 3 else { return self }
            var output = bytes
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    let sides = Int(bytes[i - 1]) + Int(bytes[i + 1]) + Int(bytes[i - width]) + Int(bytes[i + width])
                    let corners = Int(bytes[i - width - 1]) + Int(bytes[i - width + 1]) + Int(bytes[i + width - 1]) + Int(bytes[i + width + 1])
                    output[i] = UInt8((Int(bytes[i]) * 4 + sides * 2 + corners) / 16)
                }
            }
            return Gray(width: width, height: height, bytes: output)
        }
    }

    private struct Feature {
        let x: Double
        let y: Double
        let scale: Double
        let descriptor: Descriptor
    }

    private struct Descriptor: Hashable {
        let first: UInt64
        let second: UInt64
        let firstMask: UInt64
        let secondMask: UInt64

        func key(_ part: Int) -> UInt32 {
            let bits = part < 2 ? first : second
            return UInt32(part) << 16 | UInt32(truncatingIfNeeded: bits >> ((part % 2) * 32)) & 0xffff
        }

        func distance(to other: Descriptor) -> Double? {
            let a = firstMask & other.firstMask, b = secondMask & other.secondMask
            let count = a.nonzeroBitCount + b.nonzeroBitCount
            guard count >= 40 else { return nil }
            let distance = ((first ^ other.first) & a).nonzeroBitCount + ((second ^ other.second) & b).nonzeroBitCount
            let value = Double(distance) / Double(count)
            return value <= 0.22 ? value : nil
        }
    }

    private struct Signature {
        let width: Int
        let height: Int
        let features: [Feature]
        let wholeKeys: [UInt64]
        let flatColor: UInt32?

        init(_ pixels: Pixels) throws {
            width = pixels.width
            height = pixels.height
            let color = UInt32(pixels.rgba[0]) << 16 | UInt32(pixels.rgba[1]) << 8 | UInt32(pixels.rgba[2])
            let flat = stride(from: 0, to: pixels.rgba.count, by: 4).allSatisfy {
                pixels.rgba[$0] == pixels.rgba[0] && pixels.rgba[$0 + 1] == pixels.rgba[1] && pixels.rgba[$0 + 2] == pixels.rgba[2]
            }
            flatColor = flat ? color : nil
            if flat {
                features = []
                wholeKeys = [0x1_0000_0000 | UInt64(color)]
                return
            }
            var level = pixels.gray().smoothed()
            var all: [Feature] = []
            for _ in 0..<levelCount {
                try Task.checkCancellation()
                guard level.width >= 28, level.height >= 28 else { break }
                all.append(contentsOf: ImageSimilarityStep.features(level, scale: Double(width) / Double(level.width)))
                level = level.reduced().smoothed()
            }
            features = all
            let gray = pixels.gray()
            var hash: UInt64 = 0
            for y in 0..<8 {
                for x in 0..<8 {
                    let left = gray.bytes[min(height - 1, y * height / 8) * width + min(width - 1, x * width / 9)]
                    let right = gray.bytes[min(height - 1, y * height / 8) * width + min(width - 1, (x + 1) * width / 9)]
                    if left > right { hash |= UInt64(1) << (y * 8 + x) }
                }
            }
            wholeKeys = (0..<4).map { UInt64($0) << 16 | (hash >> ($0 * 16)) & 0xffff }
        }
    }

    private static let pairs: [(Int, Int, Int, Int)] = {
        var state: UInt64 = 0xa5749187d12bc863
        func coordinate() -> Int {
            state = state &* 6364136223846793005 &+ 1
            return Int(state >> 32 & 15) - 8
        }
        return (0..<128).map { _ in (coordinate(), coordinate(), coordinate(), coordinate()) }
    }()

    private static func features(_ image: Gray, scale: Double) -> [Feature] {
        let w = image.width, h = image.height, p = image.bytes
        var responses = [UInt8](repeating: 0, count: w * h)
        for y in 10..<(h - 10) {
            for x in 10..<(w - 10) {
                let i = y * w + x
                let gx = abs(Int(p[i + 1]) - Int(p[i - 1]))
                let gy = abs(Int(p[i + w]) - Int(p[i - w]))
                let diagonal = min(abs(Int(p[i + w + 1]) - Int(p[i - w - 1])), abs(Int(p[i + w - 1]) - Int(p[i - w + 1])))
                responses[i] = UInt8(min(max(gx, gy), diagonal))
            }
        }
        var buckets = [[(x: Int, y: Int, score: Int)]](repeating: [], count: 20)
        for y in 11..<(h - 11) {
            for x in 11..<(w - 11) {
                let score = Int(responses[y * w + x])
                guard score >= 12 else { continue }
                var maximum = true
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let other = Int(responses[(y + dy) * w + x + dx])
                        if other > score || (other == score && (dy < 0 || (dy == 0 && dx < 0))) { maximum = false }
                    }
                }
                guard maximum else { continue }
                let bucket = min(3, y * 4 / h) * 5 + min(4, x * 5 / w)
                if buckets[bucket].count == featuresPerLevel / 20, buckets[bucket].last!.score >= score { continue }
                let insertion = buckets[bucket].firstIndex { $0.score < score } ?? buckets[bucket].count
                buckets[bucket].insert((x, y, score), at: insertion)
                if buckets[bucket].count > featuresPerLevel / 20 { buckets[bucket].removeLast() }
            }
        }
        return buckets.flatMap { $0 }.compactMap { point in
            var bits: (UInt64, UInt64) = (0, 0), mask: (UInt64, UInt64) = (0, 0)
            for (index, pair) in pairs.enumerated() {
                let difference = Int(p[(point.y + pair.1) * w + point.x + pair.0]) - Int(p[(point.y + pair.3) * w + point.x + pair.2])
                let bit = UInt64(1) << (index % 64)
                if index < 64 {
                    if difference >= 0 { bits.0 |= bit }
                    if abs(difference) >= 5 { mask.0 |= bit }
                } else {
                    if difference >= 0 { bits.1 |= bit }
                    if abs(difference) >= 5 { mask.1 |= bit }
                }
            }
            guard mask.0.nonzeroBitCount + mask.1.nonzeroBitCount >= 48 else { return nil }
            let descriptor = Descriptor(first: bits.0, second: bits.1, firstMask: mask.0, secondMask: mask.1)
            return Feature(x: Double(point.x) * scale, y: Double(point.y) * scale, scale: scale, descriptor: descriptor)
        }
    }

    private struct Correspondence {
        let first: Feature
        let second: Feature
        let distance: Double
    }
    private struct Transform {
        let scale: Double
        let x: Double
        let y: Double
    }

    private struct Vote: Hashable {
        let scale: Int
        let x: Int
        let y: Int
    }

    private static func candidateStrength(_ matches: [Correspondence]) -> Int {
        var votes: [Vote: Int] = [:]
        for match in matches {
            let scale = match.first.scale / match.second.scale
            let key = Vote(scale: Int((log(scale) / log(1.25)).rounded()),
                           x: Int(((match.first.x - scale * match.second.x) / 48).rounded()),
                           y: Int(((match.first.y - scale * match.second.y) / 48).rounded()))
            votes[key, default: 0] += 1
        }
        return votes.values.max() ?? 0
    }

    private static func registration(_ input: [Correspondence], first: Signature, second: Signature) -> Transform? {
        var matches: [Correspondence] = []
        var occupied: Set<Int64> = []
        for match in input {
            let key = Int64(Int(match.second.x / 4)) << 32 | Int64(UInt32(Int(match.second.y / 4)))
            if occupied.insert(key).inserted { matches.append(match) }
            if matches.count == 64 { break }
        }
        guard matches.count >= 4 else { return nil }
        let minX = matches.map(\.second.x).min()!, maxX = matches.map(\.second.x).max()!
        let minY = matches.map(\.second.y).min()!, maxY = matches.map(\.second.y).max()!
        let firstSpanX = (matches.map(\.first.x).max()! - matches.map(\.first.x).min()!) / Double(first.width)
        let firstSpanY = (matches.map(\.first.y).max()! - matches.map(\.first.y).min()!) / Double(first.height)
        let secondSpanX = (maxX - minX) / Double(second.width), secondSpanY = (maxY - minY) / Double(second.height)
        guard (firstSpanX >= 0.2 && firstSpanY >= 0.2) || (secondSpanX >= 0.2 && secondSpanY >= 0.2) else { return nil }
        var best: [Correspondence] = []
        var bestError = Double.infinity
        for i in 0..<(min(32, matches.count) - 1) {
            for j in (i + 1)..<min(48, matches.count) {
                let first = matches[i], second = matches[j]
                let bx = first.second.x - second.second.x, by = first.second.y - second.second.y
                let ax = first.first.x - second.first.x, ay = first.first.y - second.first.y
                let length = bx * bx + by * by
                guard length >= 400 else { continue }
                let scale = (ax * bx + ay * by) / length
                guard scale > 0.05, scale < 20, abs(scale / (first.first.scale / first.second.scale) - 1) < 0.35 else { continue }
                let transform = Transform(scale: scale, x: first.first.x - scale * first.second.x, y: first.first.y - scale * first.second.y)
                var inliers: [Correspondence] = []
                var totalError = 0.0
                for match in matches {
                    let dx = match.first.x - (match.second.x * scale + transform.x)
                    let dy = match.first.y - (match.second.y * scale + transform.y)
                    let error = dx * dx + dy * dy
                    if error <= 9 { inliers.append(match); totalError += error }
                }
                if inliers.count > best.count || (inliers.count == best.count && totalError < bestError) {
                    best = inliers
                    bestError = totalError
                }
            }
        }
        guard best.count >= 4 else { return nil }
        let count = Double(best.count)
        let ax = best.reduce(0) { $0 + $1.first.x } / count, ay = best.reduce(0) { $0 + $1.first.y } / count
        let bx = best.reduce(0) { $0 + $1.second.x } / count, by = best.reduce(0) { $0 + $1.second.y } / count
        var numerator = 0.0, denominator = 0.0
        for match in best {
            let x = match.second.x - bx, y = match.second.y - by
            numerator += x * (match.first.x - ax) + y * (match.first.y - ay)
            denominator += x * x + y * y
        }
        guard denominator > 400 else { return nil }
        let scale = numerator / denominator
        return Transform(scale: scale, x: ax - scale * bx, y: ay - scale * by)
    }

    private static func verify(_ first: Pixels, _ second: Pixels, transform: Transform) -> (ImageSimilarityMatch.Kind, Double)? {
        let bounds = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let mapped = CGRect(x: transform.x, y: transform.y, width: Double(second.width) * transform.scale, height: Double(second.height) * transform.scale)
        let common = bounds.intersection(mapped)
        guard !common.isNull, common.width >= 12, common.height >= 12 else { return nil }
        let firstCoverage = common.width * common.height / (bounds.width * bounds.height)
        let secondCoverage = common.width * common.height / (mapped.width * mapped.height)
        guard max(firstCoverage, secondCoverage) >= 0.92 else { return nil }
        let width = min(160, max(16, Int(common.width))), height = min(160, max(16, Int(common.height)))
        var a = [UInt8](repeating: 0, count: width * height), b = a
        var colorError = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let px = common.minX + (Double(x) + 0.5) * common.width / Double(width) - 0.5
                let py = common.minY + (Double(y) + 0.5) * common.height / Double(height) - 0.5
                let qx = (px - transform.x) / transform.scale, qy = (py - transform.y) / transform.scale
                var av = 0.0, bv = 0.0
                for channel in 0..<3 {
                    let firstValue = first.sample(px, py, channel: channel), secondValue = second.sample(qx, qy, channel: channel)
                    colorError += abs(firstValue - secondValue)
                    let weight = channel == 0 ? 0.299 : (channel == 1 ? 0.587 : 0.114)
                    av += firstValue * weight; bv += secondValue * weight
                }
                a[y * width + x] = UInt8(min(255, max(0, av)))
                b[y * width + x] = UInt8(min(255, max(0, bv)))
            }
        }
        colorError /= Double(width * height * 3)
        guard colorError <= 18 else { return nil }
        let aa = Gray(width: width, height: height, bytes: a).smoothed().bytes
        let bb = Gray(width: width, height: height, bytes: b).smoothed().bytes
        var dot = 0.0, energyA = 0.0, energyB = 0.0
        var difference = 0.0, edges = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let ax = Double(aa[i + 1]) - Double(aa[i - 1]), ay = Double(aa[i + width]) - Double(aa[i - width])
                let bx = Double(bb[i + 1]) - Double(bb[i - 1]), by = Double(bb[i + width]) - Double(bb[i - width])
                dot += ax * bx + ay * by
                energyA += ax * ax + ay * ay; energyB += bx * bx + by * by
                difference += abs(ax - bx) + abs(ay - by)
                edges += abs(ax) + abs(ay) + abs(bx) + abs(by)
            }
        }
        let correlation: Double
        if energyA < 64, energyB < 64 {
            guard colorError <= 1.5 else { return nil }
            correlation = 1
        } else {
            guard energyA > 0, energyB > 0, edges > 0 else { return nil }
            correlation = dot / sqrt(energyA * energyB)
            guard correlation >= 0.93, difference / edges <= 0.28 else { return nil }
        }
        let kind: ImageSimilarityMatch.Kind
        if firstCoverage >= 0.92, secondCoverage >= 0.92 { kind = .similar }
        else { kind = firstCoverage > secondCoverage ? .secondContainsFirst : .firstContainsSecond }
        return (kind, min(1, max(0, correlation * (1 - colorError / 255))))
    }

    private static func refine(_ first: Pixels, _ second: Pixels, transform: Transform) throws -> Transform? {
        func error(_ transform: Transform) -> Double {
            var error = 0.0, count = 0
            for y in 0..<64 {
                for x in 0..<64 {
                    let bx = (Double(x) + 0.5) * Double(second.width) / 64 - 0.5
                    let by = (Double(y) + 0.5) * Double(second.height) / 64 - 0.5
                    let ax = bx * transform.scale + transform.x, ay = by * transform.scale + transform.y
                    guard ax >= 0, ay >= 0, ax < Double(first.width), ay < Double(first.height) else { continue }
                    for channel in 0..<3 {
                        error += abs(first.sample(ax, ay, channel: channel) - second.sample(bx, by, channel: channel))
                        count += 1
                    }
                }
            }
            return count > 0 ? error / Double(count) : .infinity
        }
        var best = transform, bestError = error(transform)
        guard bestError <= 24 else { return nil }
        let centerX = Double(second.width) / 2, centerY = Double(second.height) / 2
        for step in [2.0, 1.0, 0.5, 0.25] {
            try Task.checkCancellation()
            for _ in 0..<3 {
                let scaleStep = step / Double(max(second.width, second.height))
                let scaleUp = best.scale + scaleStep, scaleDown = best.scale - scaleStep
                let options = [Transform(scale: best.scale, x: best.x - step, y: best.y),
                               Transform(scale: best.scale, x: best.x + step, y: best.y),
                               Transform(scale: best.scale, x: best.x, y: best.y - step),
                               Transform(scale: best.scale, x: best.x, y: best.y + step),
                               Transform(scale: scaleUp, x: best.x - scaleStep * centerX, y: best.y - scaleStep * centerY),
                               Transform(scale: scaleDown, x: best.x + scaleStep * centerX, y: best.y + scaleStep * centerY)]
                var improved = false
                for option in options where option.scale > 0 {
                    let value = error(option)
                    if value < bestError { best = option; bestError = value; improved = true }
                }
                if !improved { break }
            }
        }
        return best
    }
}
