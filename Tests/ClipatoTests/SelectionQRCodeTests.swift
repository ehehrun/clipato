import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
@testable import Clipato

@MainActor
final class SelectionQRCodeTests: XCTestCase {
    func testQRCodeButtonOnlyAppearsForInteractiveScreenshots() throws {
        let image = try fixture([])
        let (view, _) = makeView(image: image)
        let button: NSButton = try control("qr-code", in: view)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.frame.size, CGSize(width: 28, height: 28))
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.toolTip, L("识别二维码"))
        XCTAssertEqual(button.accessibilityLabel(), L("识别二维码"))
        XCTAssertNil(view.window)

        for mode in [SelectionView.Mode.screenshot(allowsDestinationActions: false), .recording, .fixedCapture] {
            let (other, _) = makeView(image: image, mode: mode)
            XCTAssertNil(find("qr-code", in: other))
            XCTAssertNil(other.qrCodeTask)
            XCTAssertNil(other.window)
        }
    }

    func testShowingAQRCodeDoesNotRecognizeOrCopyUntilClicked() async throws {
        let (view, pasteboard) = makeView(image: try fixture(["clipato://untouched"]))
        await Task.yield()
        XCTAssertNil(view.qrCodeTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(view.window)
    }

    func testRecognitionUsesRetinaSelectionAndCopiesOriginalTextThenDismissesCapture() async throws {
        let payload = "  https://clipato.kodify.vip/?value=a%2Bb  "
        let (view, pasteboard) = makeView(image: try fixture([payload]), initialFullScreen: false)
        drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 400), in: view)
        XCTAssertEqual(view.pixelSelection, CGRect(x: 600, y: 400, width: 400, height: 400))
        var finished = false
        view.onFinish = { region, _ in
            XCTAssertNil(region, "Recognizing QR text must dismiss without saving or copying the screenshot image.")
            finished = true
        }
        let button: NSButton = try control("qr-code", in: view)

        press(button)
        let task = try XCTUnwrap(view.qrCodeTask)
        XCTAssertFalse(button.isEnabled)
        await task.value

        XCTAssertEqual(pasteboard.string(forType: .string), payload)
        XCTAssertEqual(view.assetTag, .purple)
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertTrue(finished)
        XCTAssertNil(view.qrCodeTask)
        XCTAssertTrue(button.isEnabled)
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(view.window)
    }

    func testQRCodeOutsideSelectionDoesNotReplaceClipboardOrFinishCapture() async throws {
        let (view, pasteboard) = makeView(image: try fixture(["clipato://outside-selection"]), initialFullScreen: false)
        drag(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 160), in: view)
        let region = view.selection
        var finished = false
        view.onFinish = { _, _ in finished = true }

        try await recognize(in: view)

        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertEqual(view.selection, region)
        XCTAssertFalse(finished)
        let message: NSTextField = try control("qr-code-status-message", in: view)
        XCTAssertEqual(message.stringValue, L("未识别到二维码，请调整选区后重试。"))
        let button: NSButton = try control("qr-code", in: view)
        XCTAssertTrue(button.isEnabled)
        XCTAssertNil(view.window)
    }

    func testMultipleQRCodesCopyEachPayloadOnItsOwnLine() async throws {
        let payloads = ["https://clipato.kodify.vip/first", "clipato://second"]
        let (view, pasteboard) = makeView(image: try fixture(payloads))
        var finished = false
        view.onFinish = { region, _ in
            XCTAssertNil(region)
            finished = true
        }

        try await recognize(in: view)

        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertEqual(Set(copied.components(separatedBy: "\n")), Set(payloads))
        XCTAssertEqual(copied.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(finished)
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(view.window)
    }

    func testEscapeCancelsPendingRecognitionBeforeItCanCopy() async throws {
        let (view, pasteboard) = makeView(image: try fixture(["clipato://cancelled"]))
        var cancelled = false
        view.onFinish = { region, _ in cancelled = region == nil }
        let button: NSButton = try control("qr-code", in: view)
        press(button)
        let task = try XCTUnwrap(view.qrCodeTask)

        key(53, in: view)
        await task.value

        XCTAssertTrue(cancelled)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(view.qrCodeTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(view.window)
    }

    func testMovingSelectionCancelsPendingRecognitionBeforeItCanCopy() async throws {
        let (view, pasteboard) = makeView(image: try fixture(["clipato://old-region"]), initialFullScreen: false)
        drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 400), in: view)
        let region = view.selection
        let button: NSButton = try control("qr-code", in: view)
        press(button)
        let task = try XCTUnwrap(view.qrCodeTask)

        key(124, in: view)
        await task.value

        XCTAssertEqual(view.selection.minX, region.minX + 1)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(view.qrCodeTask)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertTrue(button.isEnabled)
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)
        XCTAssertNil(view.window)
    }

    func testSuccessfulRecognitionDismissesOnlyOnceAndIgnoresFurtherCaptureActions() async throws {
        let (view, pasteboard) = makeView(image: try fixture(["clipato://copied"]), initialFullScreen: false)
        drag(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 500, y: 400), in: view)
        var completions = 0
        view.onFinish = { region, _ in
            XCTAssertNil(region)
            completions += 1
        }
        try await recognize(in: view)
        XCTAssertEqual(completions, 1)
        let status: NSView = try control("qr-code-status", in: view)
        XCTAssertTrue(status.isHidden)

        press(try control("qr-code", in: view))
        key(36, in: view)
        key(53, in: view)

        XCTAssertEqual(completions, 1)
        XCTAssertTrue(status.isHidden)
        XCTAssertEqual(pasteboard.string(forType: .string), "clipato://copied")
        XCTAssertNil(view.qrCodeTask)
        XCTAssertNil(view.window)
    }

    private func makeView(image: CGImage, mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true),
                          initialFullScreen: Bool = true) -> (SelectionView, NSPasteboard) {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.setString("untouched", forType: .string)
        addTeardownBlock { pasteboard.releaseGlobally() }
        let view = SelectionView(image: image, frame: CGRect(x: 0, y: 0, width: 800, height: 600), mode: mode,
                                 initialFullScreen: initialFullScreen, tag: .purple, colorPasteboard: pasteboard)
        return (view, pasteboard)
    }

    private func fixture(_ payloads: [String]) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        context.interpolationQuality = .none
        let imageContext = CIContext(options: [.useSoftwareRenderer: true])
        for (index, payload) in payloads.enumerated() {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"
            let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 6, y: 6))
            let qrCode = try XCTUnwrap(imageContext.createCGImage(output, from: output.extent))
            let centerX: CGFloat = payloads.count == 1 ? 800 : 550 + CGFloat(index) * 500
            let rect = CGRect(x: centerX - CGFloat(qrCode.width) / 2, y: 600 - CGFloat(qrCode.height) / 2,
                              width: CGFloat(qrCode.width), height: CGFloat(qrCode.height))
            context.draw(qrCode, in: rect)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func recognize(in view: SelectionView) async throws {
        let button: NSButton = try control("qr-code", in: view)
        press(button)
        await (try XCTUnwrap(view.qrCodeTask)).value
    }

    private func press(_ button: NSButton) {
        XCTAssertNotNil(button.action)
        XCTAssertTrue(button.sendAction(button.action, to: button.target))
    }

    private func find(_ identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let result = find(identifier, in: child) { return result }
        }
        return nil
    }

    private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        try XCTUnwrap(find(identifier, in: view) as? T, "Missing control: \(identifier)")
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) {
        view.mouseDown(with: mouse(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: mouse(.leftMouseUp, at: end, in: view))
    }

    private func key(_ code: UInt16, in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: code)!)
    }
}
