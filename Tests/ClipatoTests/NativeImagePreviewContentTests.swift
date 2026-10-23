import AppKit
import VisionKit
import XCTest
@testable import Clipato

@MainActor
final class NativeImagePreviewContentTests: XCTestCase {
    private final class PreviewWindow: NSWindow {
        var displayScale: CGFloat = 1
        override var backingScaleFactor: CGFloat { displayScale }
    }

    private func makeContent(size: NSSize = NSSize(width: 640, height: 480), scale: CGFloat = 1)
        -> (PreviewWindow, NativeImagePreviewContent) {
        _ = NSApplication.shared
        let window = PreviewWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.displayScale = scale
        let content = NativeImagePreviewContent(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        content.layoutSubtreeIfNeeded()
        return (window, content)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func imageOnScreen(_ content: NativeImagePreviewContent) -> NSRect {
        content.imageView.convert(content.imageView.bounds, to: content)
    }

    func testInitialFitDoesNotUpscaleSmallImagesAndCentersTheImage() throws {
        let (window, content) = makeContent()
        defer { content.clear(); window.close() }
        content.display(try image(width: 200, height: 100))
        let frame = imageOnScreen(content)
        XCTAssertEqual(content.zoom, 1)
        XCTAssertEqual(frame.width, 200, accuracy: 0.000001)
        XCTAssertEqual(frame.height, 100, accuracy: 0.000001)
        XCTAssertEqual(frame.midX, content.bounds.midX, accuracy: 0.01)
        XCTAssertEqual(frame.midY, content.bounds.midY, accuracy: 0.01)
        XCTAssertFalse(window.isVisible)
    }

    func testWindowResizeExpandsViewportWithoutChangingFitOrManualMagnification() throws {
        let (window, content) = makeContent()
        defer { content.clear(); window.close() }
        content.display(try image(width: 1000, height: 600))
        let original = imageOnScreen(content).size
        let originalDocument = content.imageView.frame.size
        let initialZoom = content.zoom
        let visibleBefore = content.scrollView.contentView.bounds.size
        window.setContentSize(NSSize(width: 1100, height: 800))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.zoom, initialZoom)
        XCTAssertEqual(imageOnScreen(content).width, original.width, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).height, original.height, accuracy: 0.000001)
        XCTAssertEqual(content.imageView.frame.size, originalDocument)
        XCTAssertGreaterThan(content.scrollView.contentView.bounds.width, visibleBefore.width)

        content.setZoom(1.25)
        let manualSize = imageOnScreen(content).size
        window.setContentSize(NSSize(width: 1300, height: 1000))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.zoom, 1.25)
        XCTAssertEqual(manualSize.width, 1250, accuracy: 0.000001)
        XCTAssertEqual(manualSize.height, 750, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).width, manualSize.width, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).height, manualSize.height, accuracy: 0.000001)
        XCTAssertFalse(window.isVisible)
    }

    func testShrinkingWindowAllowsScrollingAndOnlyExplicitFitChangesZoom() throws {
        let (window, content) = makeContent()
        defer { content.clear(); window.close() }
        content.display(try image(width: 1000, height: 600))
        content.setZoom(2)
        window.setContentSize(NSSize(width: 320, height: 240))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.zoom, 2)
        XCTAssertEqual(imageOnScreen(content).width, 2000, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).height, 1200, accuracy: 0.000001)
        XCTAssertLessThan(content.scrollView.contentView.bounds.width, content.imageView.frame.width)
        content.fitImage()
        XCTAssertEqual(content.zoom, 0.32, accuracy: 0.0001)
        XCTAssertEqual(imageOnScreen(content).width, 320, accuracy: 0.01)
    }

    func testOneHundredPercentUsesOnePhysicalPixelOnRetinaAndAfterBackingChange() throws {
        let (window, content) = makeContent(scale: 2)
        defer { content.clear(); window.close() }
        content.display(try image(width: 800, height: 600))
        content.setZoom(1)
        XCTAssertEqual(content.imageView.frame.size, NSSize(width: 400, height: 300))
        XCTAssertEqual(imageOnScreen(content).width * window.backingScaleFactor, 800, accuracy: 0.000001)
        content.setZoom(1.5)
        let physicalSize = imageOnScreen(content).size.applying(CGAffineTransform(scaleX: 2, y: 2))
        window.displayScale = 1
        content.viewDidChangeBackingProperties()
        XCTAssertEqual(content.zoom, 1.5)
        XCTAssertEqual(content.imageView.frame.size, NSSize(width: 800, height: 600))
        XCTAssertEqual(imageOnScreen(content).width, physicalSize.width, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).height, physicalSize.height, accuracy: 0.000001)
    }

    func testEachNewImageFitsItsActualOrientedDimensions() throws {
        let (window, content) = makeContent(size: NSSize(width: 320, height: 240))
        defer { content.clear(); window.close() }
        content.display(try image(width: 800, height: 400))
        content.setZoom(2)
        content.display(try image(width: 400, height: 800))
        XCTAssertEqual(content.zoom, 0.3, accuracy: 0.0001)
        XCTAssertEqual(content.imageView.frame.size, NSSize(width: 400, height: 800))
        XCTAssertEqual(imageOnScreen(content).width, 120, accuracy: 0.000001)
        XCTAssertEqual(imageOnScreen(content).height, 240, accuracy: 0.000001)
    }

    func testNativeOverlayTracksTheSameImageAreaThroughZoomAndResize() throws {
        let (window, content) = makeContent(scale: 2)
        defer { content.clear(); window.close() }
        content.display(try image(width: 1000, height: 600))
        content.setZoom(2)
        window.setContentSize(NSSize(width: 900, height: 700))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.overlay.trackingImageView === content.imageView)
        XCTAssertEqual(content.overlay.bounds, content.imageView.bounds)
        XCTAssertEqual(content.overlay.contentsRect, NSRect(x: 0, y: 0, width: 1, height: 1))
        let overlayFrame = content.overlay.convert(content.overlay.bounds, to: content)
        let imageFrame = imageOnScreen(content)
        XCTAssertEqual(overlayFrame.minX, imageFrame.minX, accuracy: 0.000001)
        XCTAssertEqual(overlayFrame.minY, imageFrame.minY, accuracy: 0.000001)
        XCTAssertEqual(overlayFrame.width, imageFrame.width, accuracy: 0.000001)
        XCTAssertEqual(overlayFrame.height, imageFrame.height, accuracy: 0.000001)
    }

    func testClearReleasesTheDisplayedImageAndResetsViewport() throws {
        let (window, content) = makeContent()
        defer { window.close() }
        weak var renderedImage: NSImage?
        try autoreleasepool {
            content.display(try image(width: 500, height: 300))
            renderedImage = content.imageView.image
            XCTAssertNotNil(renderedImage)
            content.setZoom(3)
            content.clear()
        }
        XCTAssertNil(renderedImage)
        XCTAssertNil(content.imageView.image)
        XCTAssertNil(content.overlay.analysis)
        XCTAssertEqual(content.imageView.frame.size, .zero)
        XCTAssertEqual(content.zoom, 1)
        XCTAssertFalse(window.isVisible)
    }
}
