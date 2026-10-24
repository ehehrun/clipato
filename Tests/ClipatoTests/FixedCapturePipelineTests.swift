import AppKit
import Combine
import ScreenCaptureKit
import XCTest
@testable import Clipato

@MainActor
final class FixedCapturePipelineTests: XCTestCase {
    func testThreeRapidRequestsAndImmediateFinishKeepEveryPNGInOrder() async throws {
        let frames = try [40, 90, 160].map { try image(red: UInt8($0)) }
        let requested = (0..<3).map { expectation(description: "Capture request \($0 + 1)") }
        var waiting: [CheckedContinuation<CGImage, Error>] = []
        let model = try makeModel { region, excluded in
            XCTAssertEqual(region.rect, CGRect(x: 10, y: 20, width: 8, height: 6))
            XCTAssertTrue(excluded.isEmpty, "This test has no overlay windows")
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(continuation)
                requested[waiting.count - 1].fulfill()
            }
        }
        let ready = expectation(description: "All PNGs moved to the workbench")
        let subscription = model.$longScreenshot.compactMap { $0 }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }

        XCTAssertTrue(model.canCaptureFixedRegion)
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.captureFixedRegion()
        XCTAssertTrue(model.canCaptureFixedRegion)
        model.finishFixedCapture()
        XCTAssertFalse(model.canCaptureFixedRegion)
        model.captureFixedRegion()
        XCTAssertEqual(model.notice, L("正在完成已接收的截图，请稍候。"))
        await fulfillment(of: [requested[0]], timeout: 3)
        XCTAssertNil(model.longScreenshot)
        waiting[0].resume(returning: frames[0])
        await fulfillment(of: [requested[1]], timeout: 3)
        XCTAssertNil(model.longScreenshot)
        waiting[1].resume(returning: frames[1])
        await fulfillment(of: [requested[2]], timeout: 3)
        XCTAssertNil(model.longScreenshot)
        waiting[2].resume(returning: frames[2])
        await fulfillment(of: [ready], timeout: 3)

        let selection = try XCTUnwrap(model.longScreenshot)
        XCTAssertEqual(selection.images.count, 3)
        XCTAssertEqual(selection.tag, .purple)
        XCTAssertEqual(try selection.images.map(redChannel), [40, 90, 160])
        let directory = try XCTUnwrap(selection.temporaryDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["1.png", "2.png", "3.png"])
        XCTAssertFalse(model.capturing)
        XCTAssertNil(model.fixedCaptureRegion)
        model.closeLongScreenshot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(model.canCaptureFixedRegion)
    }

    func testIdenticalScreensAreRetainedAsSeparateAcceptedCaptures() async throws {
        let frame = try image(red: 80)
        var requests = 0
        let model = try makeModel { _, _ in requests += 1; return frame }
        let ready = expectation(description: "Repeated pictures remain separate")
        let subscription = model.$longScreenshot.compactMap { $0 }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(try XCTUnwrap(model.longScreenshot).images.count, 3)
        XCTAssertEqual(try XCTUnwrap(model.longScreenshot).images.map(redChannel), [80, 80, 80])
        model.closeLongScreenshot()
    }

    func testFailureStopsRemainingQueueReportsMissingRequestsAndKeepsSuccessfulImagesForRetry() async throws {
        let frames = try [40, 80, 120, 160].map { try image(red: UInt8($0)) }
        let captureError = NSError(domain: "CaptureFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "显示器已断开"])
        var requests = 0
        let model = try makeModel { _, _ in
            requests += 1
            if requests == 2 { throw captureError }
            return frames[requests - 1]
        }
        let stopped = expectation(description: "Failed capture drains no more requests")
        let stopSubscription = model.$capturing.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [stopped], timeout: 3)
        stopSubscription.cancel()
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(model.hasFixedCaptures)
        XCTAssertNil(model.longScreenshot)
        XCTAssertEqual(model.errorMessage, L("连续截图未完成：\(captureError.localizedDescription)\n已保留 \(1) 张截图，\(2) 次请求未完成。可继续截取，或完成已有图片。"))

        let ready = expectation(description: "Continue after failure")
        let subscription = model.$longScreenshot.compactMap { $0 }.sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(requests, 4)
        XCTAssertEqual(try XCTUnwrap(model.longScreenshot).images.map(redChannel), [40, 120, 160])
        model.closeLongScreenshot()
    }

    func testRealPNGWriteFailureCannotPublishAnIncompleteWorkbenchOrContinueQueuedCaptures() async throws {
        let frame = try image(red: 45)
        var requests = 0
        let model = try makeModel { _, _ in requests += 1; return frame }
        // Remove only this test's prepared directory so the actual PNG writer fails.
        let prepared = try XCTUnwrap(preparedDirectories[ObjectIdentifier(model)])
        try FileManager.default.removeItem(at: prepared)
        let stopped = expectation(description: "PNG failure reported")
        let subscription = model.$capturing.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        defer { subscription.cancel() }
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(model.hasFixedCaptures)
        XCTAssertNil(model.longScreenshot)
        XCTAssertEqual(model.errorMessage, L("连续截图未完成：\(LibraryError.imageWrite.localizedDescription)\n已保留 \(0) 张截图，\(3) 次请求未完成。可继续截取，或完成已有图片。"))
    }

    func testPermissionLossPreservesAcceptedImagesAndRecoveryClearsInlineDiagnostic() async throws {
        let frame = try image(red: 80)
        let denied = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let captureError = ScreenCapturePermission.localizedError(denied)
        var requests = 0
        let model = try makeModel { _, _ in
            requests += 1
            if requests == 2 { throw captureError }
            return frame
        }
        let region = try XCTUnwrap(model.fixedCaptureRegion)
        let directory = try XCTUnwrap(preparedDirectories[ObjectIdentifier(model)])
        let stopped = expectation(description: "Permission failure stops the remaining requests")
        let stopping = model.$capturing.dropFirst().filter { !$0 }.sink { _ in stopped.fulfill() }
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [stopped], timeout: 3)
        stopping.cancel()

        XCTAssertEqual(requests, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.section, .security)
        XCTAssertEqual(model.fixedCaptureRegion, region)
        XCTAssertTrue(model.hasFixedCaptures)
        XCTAssertEqual(model.screenCapturePermissionError, L("连续截图未完成：\(captureError.localizedDescription)\n已保留 \(1) 张截图，\(2) 次请求未完成。可继续截取，或完成已有图片。"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["1.png"])
        XCTAssertNil(model.longScreenshot)

        let ready = expectation(description: "The existing image can be completed after permission returns")
        let completed = model.$longScreenshot.compactMap { $0 }.sink { _ in ready.fulfill() }
        defer { completed.cancel() }
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [ready], timeout: 3)

        XCTAssertEqual(requests, 3)
        XCTAssertNil(model.screenCapturePermissionError)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try XCTUnwrap(model.longScreenshot).images.count, 2)
        model.closeLongScreenshot()
    }

    private var preparedDirectories: [ObjectIdentifier: URL] = [:]

    func testMovingBetweenCapturesUsesNewRegionButDoesNotMoveAnInFlightCapture() async throws {
        let frame = try image(red: 40)
        var regions: [RecordingRegion] = []
        let model = try makeModel { region, _ in regions.append(region); return frame }
        let initial = try XCTUnwrap(model.fixedCaptureRegion)
        let moved = RecordingRegion(displayID: initial.displayID, rect: initial.rect.offsetBy(dx: 11, dy: 15))
        let first = expectation(description: "First frame saved")
        let subscription = model.$capturing.dropFirst().filter { !$0 }.sink { _ in first.fulfill() }
        model.captureFixedRegion()
        model.moveFixedCapture(to: moved)
        XCTAssertEqual(model.fixedCaptureRegion, initial)
        await fulfillment(of: [first], timeout: 3)
        subscription.cancel()
        model.moveFixedCapture(to: moved)
        XCTAssertEqual(model.fixedCaptureRegion, moved)
        let finished = expectation(description: "Moved frame saved")
        let finishedSubscription = model.$longScreenshot.compactMap { $0 }.sink { _ in finished.fulfill() }
        defer { finishedSubscription.cancel() }
        model.captureFixedRegion()
        model.finishFixedCapture()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(regions, [initial, moved])
        model.closeLongScreenshot()
    }

    private func makeModel(capture: @escaping (RecordingRegion, [CGWindowID]) async throws -> CGImage) throws -> AppModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato-PipelineTests-\(UUID().uuidString)")
        let defaultsName = "Clipato.FixedCaptureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), fixedCaptureImage: capture)
        let directory = try model.beginFixedCapture(region: RecordingRegion(displayID: 7, rect: CGRect(x: 10, y: 20, width: 8, height: 6)), tag: .purple)
        preparedDirectories[ObjectIdentifier(model)] = directory
        addTeardownBlock {
            for url in [root, directory] where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            defaults.removePersistentDomain(forName: defaultsName)
        }
        return model
    }

    private func image(red: UInt8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try XCTUnwrap(context.makeImage())
    }

    private func redChannel(_ image: CGImage) throws -> UInt8 {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.data!.assumingMemoryBound(to: UInt8.self)[0]
    }
}
