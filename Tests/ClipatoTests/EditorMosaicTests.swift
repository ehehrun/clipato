import AppKit
import XCTest
@testable import Clipato

@MainActor
final class EditorMosaicTests: XCTestCase {
    private func canvas(scale: CGFloat = 0.5) throws -> EditorImageCanvas {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = EditorImageCanvas(image: try XCTUnwrap(context.makeImage()))
        canvas.frame = CGRect(x: 0, y: 0, width: 800 * scale + 40, height: 600 * scale + 60)
        canvas.imageFrame = CGRect(x: 20, y: 30, width: 800 * scale, height: 600 * scale)
        canvas.imageScale = scale
        canvas.tool = .mosaic
        return canvas
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in canvas: EditorImageCanvas) -> NSEvent {
        let location = CGPoint(x: canvas.imageFrame.minX + point.x * canvas.imageScale,
                               y: canvas.imageFrame.minY + point.y * canvas.imageScale)
        return NSEvent.mouseEvent(with: type, location: canvas.convert(location, to: nil), modifierFlags: [], timestamp: 0,
                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func paint(_ points: [CGPoint], in canvas: EditorImageCanvas) {
        canvas.mouseDown(with: event(.leftMouseDown, at: points[0], in: canvas))
        for point in points.dropFirst().dropLast() {
            canvas.mouseDragged(with: event(.leftMouseDragged, at: point, in: canvas))
        }
        canvas.mouseUp(with: event(.leftMouseUp, at: points.last!, in: canvas))
    }

    func testBrushStoresSourcePixelsIndependentOfZoomIncludingReleasePosition() throws {
        let points = [CGPoint(x: 100, y: 150), CGPoint(x: 160, y: 180), CGPoint(x: 240, y: 220)]
        for scale in [CGFloat(0.25), 0.5, 2] {
            let canvas = try canvas(scale: scale)
            canvas.mosaicBrushSize = 80
            canvas.mosaicSize = 24
            var added: [ImageAnnotation] = []
            canvas.onAnnotation = { added.append($0) }
            paint(points, in: canvas)
            let stroke = try XCTUnwrap(added.first)
            XCTAssertEqual(added.count, 1)
            XCTAssertEqual(stroke.points, points)
            XCTAssertEqual(stroke.width, 80)
            XCTAssertEqual(stroke.mosaicSize, 24)
            XCTAssertEqual(stroke.mosaicShape, .brush)
        }
    }

    func testClickPaintsOneBrushDotButDoesNotCommitEmptyRectangle() throws {
        let canvas = try canvas()
        let point = CGPoint(x: 100, y: 100)
        paint([point], in: canvas)
        let dot = try XCTUnwrap(canvas.annotations.first)
        XCTAssertEqual(dot.points, [point])
        XCTAssertTrue(dot.mosaicMask.contains(point))
        canvas.mosaicShape = .rectangle
        paint([CGPoint(x: 400, y: 400)], in: canvas)
        XCTAssertEqual(canvas.annotations, [dot])
    }

    func testRectangleKeepsOnlyEndpointsAndClampsToImage() throws {
        let canvas = try canvas()
        canvas.mosaicShape = .rectangle
        paint([CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 200), CGPoint(x: 1000, y: 900)], in: canvas)
        let rectangle = try XCTUnwrap(canvas.annotations.first)
        XCTAssertEqual(rectangle.mosaicShape, .rectangle)
        XCTAssertEqual(rectangle.points, [CGPoint(x: 100, y: 100), CGPoint(x: 800, y: 600)])
        XCTAssertEqual(rectangle.mosaicMask.boundingBoxOfPath, CGRect(x: 100, y: 100, width: 700, height: 500))
    }

    func testPaintingOverExistingMarkupAddsAnotherStrokeAndUndoKeepsEarlierLayers() throws {
        let canvas = try canvas()
        let point = CGPoint(x: 100, y: 100)
        let text = ImageAnnotation(tool: .text, points: [point], color: .red, width: 0,
                                   text: "原有文字", fontSize: 24, textWidth: 200)
        canvas.annotations = [text]
        var changes: [AnnotationChange] = []
        canvas.onAnnotation = { changes.append(.add($0)) }
        paint([point, CGPoint(x: 200, y: 100)], in: canvas)
        let firstPass = canvas.annotations
        paint([point, CGPoint(x: 200, y: 100)], in: canvas)
        XCTAssertEqual(canvas.annotations.count, 3, "Mosaic paints through an existing annotation instead of selecting it")
        XCTAssertTrue(canvas.subviews.isEmpty, "Painting over text must not start the text editor")
        XCTAssertEqual(changes.count, 2)
        changes[1].undo(in: &canvas.annotations)
        XCTAssertEqual(canvas.annotations, firstPass)
        changes[1].apply(to: &canvas.annotations)
        XCTAssertEqual(canvas.annotations.count, 3)
    }

    func testOtherToolCannotSelectOrDeleteMosaicButPaintingCanBeUndoneAndRedone() throws {
        for shape in MosaicShape.allCases {
            let canvas = try canvas()
            canvas.mosaicShape = shape
            var addition: AnnotationChange?
            canvas.onAnnotation = { addition = .add($0) }
            paint([CGPoint(x: 200, y: 200), CGPoint(x: 300, y: 230)], in: canvas)
            let original = canvas.annotations
            let change = try XCTUnwrap(addition)
            var edits: [AnnotationChange] = []
            canvas.onAnnotationChange = { edits.append($0) }
            canvas.tool = .rectangle
            paint([CGPoint(x: 250, y: 215)], in: canvas)
            for code in [UInt16(51), UInt16(117)] {
                let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                             context: nil, characters: code == 51 ? "\u{7f}" : "\u{f728}",
                                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                canvas.keyDown(with: delete)
                XCTAssertEqual(canvas.annotations, original, "\(shape) must not be selected for deletion")
            }
            XCTAssertTrue(edits.isEmpty)
            change.undo(in: &canvas.annotations)
            XCTAssertTrue(canvas.annotations.isEmpty)
            change.apply(to: &canvas.annotations)
            XCTAssertEqual(canvas.annotations, original)
        }
    }

    func testReadOnlyAndCancelledStrokeDoNotCommitMosaic() throws {
        let canvas = try canvas()
        let point = CGPoint(x: 100, y: 100)
        canvas.allowsAnnotation = false
        paint([point, CGPoint(x: 200, y: 200)], in: canvas)
        XCTAssertTrue(canvas.annotations.isEmpty)
        canvas.allowsAnnotation = true
        canvas.mouseDown(with: event(.leftMouseDown, at: point, in: canvas))
        canvas.mouseDragged(with: event(.leftMouseDragged, at: CGPoint(x: 200, y: 200), in: canvas))
        canvas.cancelStroke()
        canvas.mouseUp(with: event(.leftMouseUp, at: CGPoint(x: 300, y: 300), in: canvas))
        XCTAssertTrue(canvas.annotations.isEmpty)
    }
}
