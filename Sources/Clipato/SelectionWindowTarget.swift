import CoreGraphics
import Foundation

struct SelectionWindowTarget: Equatable {
    let windowID: CGWindowID
    let frame: CGRect

    static func targets(in windowInfo: [[String: Any]], displayFrame: CGRect,
                        shareableWindowIDs: Set<CGWindowID>) throws -> [Self] {
        var targets: [Self] = []
        var occludingFrames: [CGRect] = []
        occludingFrames.reserveCapacity(windowInfo.count)

        for info in windowInfo {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let windowLayer = info[kCGWindowLayer as String] as? Int,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                throw CocoaError(.propertyListReadCorrupt, userInfo: [
                    NSDebugDescriptionErrorKey: "Invalid CGWindowListCopyWindowInfo entry."
                ])
            }
            guard alpha > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite,
                  frame.size.width > 0, frame.size.height > 0 else { continue }
            let visibleFrame = frame.intersection(displayFrame)
            guard !visibleFrame.isEmpty else { continue }

            if (0..<20).contains(windowLayer), shareableWindowIDs.contains(windowID),
               displayFrame.contains(frame),
               !occludingFrames.contains(where: { !$0.intersection(frame).isEmpty }) {
                targets.append(Self(windowID: windowID,
                                    frame: frame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)))
            }
            // Nonselectable and cross-display foreground windows still hide pixels in the frozen screenshot.
            occludingFrames.append(visibleFrame)
        }
        return targets
    }
}
