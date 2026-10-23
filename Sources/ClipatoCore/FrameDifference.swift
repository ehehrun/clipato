/// Compares small RGBA thumbnails. The strongest tile keeps a local edit from
/// disappearing into the average of a mostly unchanged desktop.
public enum FrameDifference {
    public static func score(
        previous: [UInt8], current: [UInt8], width: Int, height: Int
    ) -> Double {
        precondition(width > 0 && height > 0)
        precondition(previous.count == width * height * 4 && current.count == previous.count)

        let tileSize = 16
        var strongest = 0.0
        for top in stride(from: 0, to: height, by: tileSize) {
            let bottom = min(top + tileSize, height)
            for left in stride(from: 0, to: width, by: tileSize) {
                let right = min(left + tileSize, width)
                var difference = 0
                for y in top..<bottom {
                    for x in left..<right {
                        let offset = (y * width + x) * 4
                        for channel in 0..<3 {
                            difference += abs(Int(current[offset + channel]) - Int(previous[offset + channel]))
                        }
                    }
                }
                let channels = (right - left) * (bottom - top) * 3
                strongest = max(strongest, Double(difference) / Double(channels * 255))
            }
        }
        return strongest
    }
}
