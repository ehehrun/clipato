import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class SurfaceBorderTests: XCTestCase {
    func testFractionalGridFramesKeepCompleteOpaqueEdgesAtBothDisplayScales() throws {
        for scale: CGFloat in [1, 2] {
            for offset: CGFloat in [0, 0.25, 0.5, 0.9] {
                let frame = CGRect(x: 8 + offset, y: 8 + offset, width: 223.0 / 3, height: 30 * 20.0 / 14)
                let path = SurfaceBorder.path(in: frame, cornerRadius: 6, lineWidth: 0.5, displayScale: scale)
                let pixelWidth = Int(ceil((frame.maxX + 8) * scale))
                let pixelHeight = Int(ceil((frame.maxY + 8) * scale))
                let context = try XCTUnwrap(CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.translateBy(x: 0, y: CGFloat(pixelHeight))
                context.scaleBy(x: scale, y: -scale)
                context.translateBy(x: frame.minX, y: frame.minY)
                context.addPath(path.cgPath)
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fillPath()
                let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
                let left = Int(ceil(frame.minX * scale))
                let right = Int(floor(frame.maxX * scale)) - 1
                let top = Int(ceil(frame.minY * scale))
                let bottom = Int(floor(frame.maxY * scale)) - 1
                for y in (top + Int(8 * scale))..<(bottom - Int(8 * scale)) {
                    XCTAssertGreaterThanOrEqual(pixels[(y * pixelWidth + left) * 4 + 3], 254)
                    XCTAssertGreaterThanOrEqual(pixels[(y * pixelWidth + right) * 4 + 3], 254)
                }
                for x in (left + Int(8 * scale))..<(right - Int(8 * scale)) {
                    XCTAssertGreaterThanOrEqual(pixels[(top * pixelWidth + x) * 4 + 3], 254)
                    XCTAssertGreaterThanOrEqual(pixels[(bottom * pixelWidth + x) * 4 + 3], 254)
                }
                XCTAssertEqual(pixels[(((top + bottom) / 2) * pixelWidth + (left + right) / 2) * 4 + 3], 0)
                let drawnBounds = path.boundingRect.offsetBy(dx: frame.minX, dy: frame.minY)
                XCTAssertTrue(frame.contains(drawnBounds), "The border must stay inside the scroll view's clip.")
            }
        }
    }

    func testSelectedBorderAndTransientEmptyLayoutStayInsideBounds() {
        for scale: CGFloat in [1, 2] {
            let frame = CGRect(x: 0.3, y: 0.7, width: 215.3, height: 220.6)
            let selected = SurfaceBorder.path(in: frame, cornerRadius: 8, lineWidth: 1.5, displayScale: scale)
            XCTAssertTrue(frame.contains(selected.boundingRect.offsetBy(dx: frame.minX, dy: frame.minY)))
            XCTAssertTrue(SurfaceBorder.path(in: .zero, cornerRadius: 8, lineWidth: 0.5, displayScale: scale).isEmpty)
        }
    }
}
