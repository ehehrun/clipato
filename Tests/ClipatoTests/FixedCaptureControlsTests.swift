import AppKit
import XCTest
@testable import Clipato

@MainActor
final class FixedCaptureControlsTests: XCTestCase {
    func testBorderInnerEdgeExactlyMatchesCaptureRegionWithoutCoveringPixels() {
        for region in [
            CGRect(x: 40, y: 80, width: 640, height: 480),
            CGRect(x: -1600, y: -300, width: 1600, height: 900),
            CGRect(x: -0.5, y: 1.5, width: 1, height: 1)
        ] {
            let frame = FixedCaptureOverlay.borderFrame(for: region)
            let view = FixedCaptureBorderView(frame: CGRect(origin: .zero, size: frame.size))
            let innerEdge = view.captureRect.offsetBy(dx: frame.minX, dy: frame.minY)
            XCTAssertEqual(innerEdge, region)
            XCTAssertEqual(frame.minX, region.minX - 3)
            XCTAssertEqual(frame.minY, region.minY - 3)
            XCTAssertEqual(frame.maxX, region.maxX + 3)
            XCTAssertEqual(frame.maxY, region.maxY + 3)
            XCTAssertNil(view.window)
        }
    }

    func testToolbarStaysWithinSelectedDisplaysVisibleFrameAtEveryEdge() {
        let visible = CGRect(x: -1600, y: -300, width: 1600, height: 900)
        for region in [
            CGRect(x: -1400, y: -100, width: 600, height: 400),
            CGRect(x: -1600, y: -300, width: 100, height: 100),
            CGRect(x: -100, y: -300, width: 100, height: 100),
            CGRect(x: -1600, y: 500, width: 100, height: 100),
            CGRect(x: -100, y: 500, width: 100, height: 100),
            visible
        ] {
            XCTAssertTrue(visible.contains(FixedCaptureOverlay.controlsFrame(for: region, within: visible)))
        }
        let ordinary = CGRect(x: -1400, y: -100, width: 600, height: 400)
        XCTAssertEqual(FixedCaptureOverlay.controlsFrame(for: ordinary, within: visible).maxY, ordinary.minY - 10)
        let bottom = CGRect(x: -1400, y: -300, width: 600, height: 400)
        XCTAssertEqual(FixedCaptureOverlay.controlsFrame(for: bottom, within: visible).minY, bottom.maxY + 10)
    }

    func testBusyCaptureAcceptsRepeatedRequestsAndFinishWaitsForPendingImages() throws {
        let controls = makeControls()
        let capture: NSButton = try control("fixed-capture-take", in: controls)
        let finish: NSButton = try control("fixed-capture-finish", in: controls)
        let cancel: NSButton = try control("fixed-capture-cancel", in: controls)
        var captures = 0
        var finishes = 0
        controls.onCapture = {
            captures += 1
            controls.update(count: 0, busy: true, pending: captures)
        }
        controls.onFinish = { finishes += 1 }
        XCTAssertTrue(capture.isEnabled)
        XCTAssertEqual(capture.title, "")
        XCTAssertEqual(finish.title, "")
        XCTAssertEqual(capture.accessibilityLabel(), L("截一张"))
        XCTAssertEqual(finish.accessibilityLabel(), L("完成长图"))
        XCTAssertFalse(finish.isEnabled)
        finish.performClick(nil)
        XCTAssertEqual(finishes, 0)

        capture.performClick(nil)
        capture.performClick(nil)
        XCTAssertEqual(captures, 2)
        XCTAssertTrue(capture.isEnabled)
        XCTAssertTrue(finish.isEnabled)
        XCTAssertFalse(cancel.isEnabled)
        let metrics: NSTextField = try control("fixed-capture-count", in: controls)
        XCTAssertEqual(metrics.stringValue, L("已截 \(0) 张 · 待截 \(2) 张") + " · F4")
        finish.performClick(nil)
        finish.performClick(nil)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(finish.isEnabled)
        XCTAssertFalse(capture.isEnabled)
        controls.update(count: 2, busy: false)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(finish.isEnabled, "A failed save must permit retry")
    }

    func testCancelCanBeDeclinedAndNeverPermanentlyLocksSession() throws {
        let controls = makeControls()
        let capture: NSButton = try control("fixed-capture-take", in: controls)
        let finish: NSButton = try control("fixed-capture-finish", in: controls)
        let cancel: NSButton = try control("fixed-capture-cancel", in: controls)
        var cancellations = 0
        controls.onCancel = { cancellations += 1 }
        controls.update(count: 3, busy: true)
        cancel.performClick(nil)
        XCTAssertEqual(cancellations, 0)
        controls.update(count: 3, busy: false)
        cancel.performClick(nil)
        XCTAssertEqual(cancellations, 1)
        controls.update(count: 3, busy: false)
        XCTAssertTrue(capture.isEnabled)
        XCTAssertTrue(finish.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
    }

    func testCountShortcutAndTagStayIndependentOfCaptureProgress() throws {
        let controls = makeControls()
        let picker: NativeAssetTagPicker = try control("fixed-capture-tag", in: controls)
        let count: NSTextField = try control("fixed-capture-count", in: controls)
        let status: NSTextField = try control("fixed-capture-status", in: controls)
        var tags: [AssetTag?] = []
        controls.onTagChange = { tags.append($0) }
        controls.reset(tag: .green, shortcutDescription: "F4")
        XCTAssertEqual(picker.assetTag, .green)
        XCTAssertEqual(count.stringValue, L("已截 \(0) 张") + " · F4")
        XCTAssertTrue(tags.isEmpty)
        picker.selectItem(withTitle: AssetTag.purple.title)
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(tags, [.purple])

        controls.update(count: 12, busy: true)
        XCTAssertEqual(picker.assetTag, .purple)
        XCTAssertEqual(count.stringValue, L("已截 \(12) 张") + " · F4")
        XCTAssertEqual(status.stringValue, L("处理中…"))
        XCTAssertFalse(picker.isEnabled)
        picker.selectItem(withTitle: AssetTag.red.title)
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(tags, [.purple])
        controls.reset(tag: nil, shortcutDescription: L("鼠标点击截取"))
        XCTAssertNil(picker.assetTag)
        XCTAssertEqual(status.stringValue, L("连续截图"))
        XCTAssertTrue(picker.isEnabled)
    }

    func testControlsHaveDistinctClickTargetsAndSupportFirstMouse() throws {
        let controls = makeControls()
        controls.layoutSubtreeIfNeeded()
        let ids = ["fixed-capture-move", "fixed-capture-restore", "fixed-capture-tag", "fixed-capture-take", "fixed-capture-finish", "fixed-capture-cancel"]
        var frames: [CGRect] = []
        for id in ids {
            let control: NSControl = try control(id, in: controls)
            let frame = controls.convert(control.bounds, from: control)
            XCTAssertTrue(controls.bounds.contains(frame))
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertTrue(control.acceptsFirstMouse(for: nil))
            frames.append(frame)
        }
        for index in 1..<frames.count { XCTAssertLessThan(frames[index - 1].maxX, frames[index].minX) }
        for id in ["fixed-capture-take", "fixed-capture-finish", "fixed-capture-cancel", "fixed-capture-restore"] {
            let button: NSButton = try control(id, in: controls)
            XCTAssertEqual(button.frame.size, CGSize(width: 28, height: 28))
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertNotNil(button.image)
        }
    }

    func testLanguageRefreshKeepsCompactIconButtonsAndAllLabelsVisible() throws {
        let settings = LanguageSettings.shared
        let originalLanguage = settings.language
        let originalResolvedLanguage = settings.resolvedLanguage
        let originalPreference = UserDefaults.standard.object(forKey: "language")
        defer {
            settings.setLanguage(originalLanguage, preferredLanguages: [originalResolvedLanguage.rawValue])
            if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: "language") }
            else { UserDefaults.standard.removeObject(forKey: "language") }
        }
        let controls = makeControls()
        controls.reset(tag: .purple, shortcutDescription: "F4")
        controls.update(count: 999, busy: false)
        let status: NSTextField = try control("fixed-capture-status", in: controls)
        let metrics: NSTextField = try control("fixed-capture-count", in: controls)
        let picker: NativeAssetTagPicker = try control("fixed-capture-tag", in: controls)
        let capture: NSButton = try control("fixed-capture-take", in: controls)
        let finish: NSButton = try control("fixed-capture-finish", in: controls)
        for language in AppLanguage.allCases where language != .system {
            settings.setLanguage(language)
            controls.layoutSubtreeIfNeeded()
            XCTAssertEqual(capture.title, "", language.rawValue)
            XCTAssertEqual(finish.title, "", language.rawValue)
            XCTAssertEqual(capture.accessibilityLabel(), L("截一张"), language.rawValue)
            XCTAssertEqual(finish.accessibilityLabel(), L("完成长图"), language.rawValue)
            XCTAssertEqual(finish.toolTip, L("按截取顺序拼成长图并保存"), language.rawValue)
            XCTAssertEqual(picker.assetTag, .purple, language.rawValue)
            XCTAssertGreaterThanOrEqual(status.frame.width + 0.5, status.intrinsicContentSize.width, language.rawValue)
            XCTAssertGreaterThanOrEqual(metrics.frame.width + 0.5, metrics.intrinsicContentSize.width, language.rawValue)
            XCTAssertGreaterThanOrEqual(picker.frame.width + 0.5, picker.preferredWidth, language.rawValue)
            for view in [status, metrics, picker, capture, finish] {
                XCTAssertTrue(controls.bounds.contains(controls.convert(view.bounds, from: view)), language.rawValue)
            }
            XCTAssertEqual(capture.frame.size, CGSize(width: 28, height: 28), language.rawValue)
            XCTAssertEqual(finish.frame.size, CGSize(width: 28, height: 28), language.rawValue)
            XCTAssertEqual(capture.imagePosition, .imageOnly, language.rawValue)
            XCTAssertEqual(finish.imagePosition, .imageOnly, language.rawValue)
            XCTAssertTrue(capture.isEnabled)
            XCTAssertTrue(finish.isEnabled)
            if language == .simplifiedChinese {
                XCTAssertLessThan(controls.preferredSize.width, 550)
                XCTAssertLessThanOrEqual(controls.preferredSize.height, 48)
            }
            XCTAssertNil(controls.window)
        }
        controls.update(count: 999_999, busy: true, pending: 99_999)
        controls.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(metrics.frame.width + 0.5, metrics.intrinsicContentSize.width)
        XCTAssertTrue(controls.bounds.contains(controls.convert(metrics.bounds, from: metrics)))
    }

    func testShortcutDescriptionChangesPreserveCountTagAndBusyControls() throws {
        let controls = makeControls()
        controls.reset(tag: .blue, shortcutDescription: "F4")
        controls.update(count: 7, busy: true)
        let picker: NativeAssetTagPicker = try control("fixed-capture-tag", in: controls)
        let count: NSTextField = try control("fixed-capture-count", in: controls)
        let status: NSTextField = try control("fixed-capture-status", in: controls)
        let capture: NSButton = try control("fixed-capture-take", in: controls)
        let finish: NSButton = try control("fixed-capture-finish", in: controls)
        let cancel: NSButton = try control("fixed-capture-cancel", in: controls)

        controls.updateShortcutDescription("⌥F4")
        XCTAssertEqual(count.stringValue, L("已截 \(7) 张") + " · ⌥F4")
        XCTAssertEqual(capture.toolTip, L("截取固定区域 · \("⌥F4")"))
        XCTAssertEqual(picker.assetTag, .blue)
        XCTAssertEqual(status.stringValue, L("处理中…"))
        XCTAssertFalse(capture.isEnabled)
        XCTAssertFalse(finish.isEnabled)
        XCTAssertFalse(cancel.isEnabled)
        XCTAssertFalse(picker.isEnabled)

        controls.update(count: 7, busy: false)
        controls.updateShortcutDescription(L("快捷键已禁用"))
        XCTAssertEqual(count.stringValue, L("已截 \(7) 张") + " · " + L("快捷键已禁用"))
        XCTAssertEqual(picker.assetTag, .blue)
        XCTAssertEqual(status.stringValue, L("连续截图"))
        XCTAssertTrue(capture.isEnabled)
        XCTAssertTrue(finish.isEnabled)
        XCTAssertTrue(cancel.isEnabled)
        XCTAssertTrue(picker.isEnabled)
    }

    func testFixedRegionConfigurationRetainsAllNativePixelsWithoutVideoLimit() throws {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 40.5, y: 20, width: 2200, height: 1300))
        let configuration = try region.configuration(displayID: 7,
            contentRect: CGRect(x: -3000, y: 0, width: 3000, height: 2000), pointPixelScale: 2, maxDimension: Int.max)
        XCTAssertEqual(configuration.sourceRect, region.rect)
        XCTAssertEqual(configuration.width, 4400)
        XCTAssertEqual(configuration.height, 2600)
        XCTAssertThrowsError(try region.configuration(displayID: 8,
            contentRect: CGRect(x: 0, y: 0, width: 3000, height: 2000), pointPixelScale: 2, maxDimension: Int.max))
        XCTAssertThrowsError(try region.configuration(displayID: 7,
            contentRect: CGRect(x: 0, y: 0, width: 2000, height: 1200), pointPixelScale: 2, maxDimension: Int.max))
    }

    func testMovementAndRestoreDisableWhileCaptureQueueIsBusy() throws {
        let controls = makeControls()
        let handle: FixedCaptureMoveHandle = try control("fixed-capture-move", in: controls)
        let restore: NSButton = try control("fixed-capture-restore", in: controls)
        var nudges: [CGSize] = []
        var restores = 0
        controls.onNudge = { nudges.append($0) }
        controls.onRestore = { restores += 1 }
        XCTAssertTrue(handle.isEnabled)
        XCTAssertFalse(restore.isEnabled)
        XCTAssertTrue(handle.needsPanelToBecomeKey)

        controls.updatePosition(RecordingRegion(displayID: 7, rect: CGRect(x: 40, y: 20, width: 500, height: 300)), atInitialPosition: false)
        XCTAssertTrue(restore.isEnabled)
        restore.performClick(nil)
        XCTAssertEqual(restores, 1)
        controls.update(count: 1, busy: true, pending: 2)
        XCTAssertFalse(handle.isEnabled)
        XCTAssertFalse(restore.isEnabled)
        handle.keyDown(with: key(124))
        restore.performClick(nil)
        XCTAssertTrue(nudges.isEmpty)
        XCTAssertEqual(restores, 1)

        controls.update(count: 3, busy: false)
        XCTAssertTrue(handle.isEnabled)
        XCTAssertTrue(restore.isEnabled)
        controls.update(count: 3, busy: false, finishing: true)
        XCTAssertFalse(handle.isEnabled)
        XCTAssertFalse(restore.isEnabled)
        XCTAssertNil(handle.window)
    }

    func testMoveHandleArrowsUseScreenDirectionsAndExactOneOrTenPointSteps() throws {
        let controls = makeControls()
        let handle: FixedCaptureMoveHandle = try control("fixed-capture-move", in: controls)
        var nudges: [CGSize] = []
        controls.onNudge = { nudges.append($0) }
        for code in [UInt16(123), 124, 125, 126] { handle.keyDown(with: key(code)) }
        for code in [UInt16(123), 124, 125, 126] { handle.keyDown(with: key(code, modifiers: .shift)) }
        XCTAssertEqual(nudges, [
            CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
            CGSize(width: 0, height: -1), CGSize(width: 0, height: 1),
            CGSize(width: -10, height: 0), CGSize(width: 10, height: 0),
            CGSize(width: 0, height: -10), CGSize(width: 0, height: 10)
        ])
        XCTAssertNil(handle.window)
    }

    func testDragSnapsEachAxisOnlyWithinSixPointsAndCanBeBypassed() {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        let initial = CGRect(x: -1400, y: 100, width: 640, height: 480)
        XCTAssertEqual(FixedCaptureOverlay.movedFrame(initial.offsetBy(dx: 6, dy: -6), reference: initial, within: screen, snap: true), initial)
        XCTAssertEqual(FixedCaptureOverlay.movedFrame(initial.offsetBy(dx: 6.5, dy: -6), reference: initial, within: screen, snap: true), initial.offsetBy(dx: 6.5, dy: 0))
        XCTAssertEqual(FixedCaptureOverlay.movedFrame(initial.offsetBy(dx: -3, dy: 30), reference: initial, within: screen, snap: true), initial.offsetBy(dx: 0, dy: 30))
        XCTAssertEqual(FixedCaptureOverlay.movedFrame(initial.offsetBy(dx: 1, dy: 1), reference: initial, within: screen, snap: false), initial.offsetBy(dx: 1, dy: 1))
    }

    func testMovingRegionClampsOnOriginalDisplayWithoutResizingIncludingSinglePoint() throws {
        let screen = CGRect(x: -1920, y: -100, width: 1920, height: 1080)
        for size in [CGSize(width: 640, height: 480), CGSize(width: 1, height: 1), screen.size] {
            let initial = CGRect(origin: screen.origin, size: size)
            for delta in [CGSize(width: -5000, height: -5000), CGSize(width: 5000, height: 5000), CGSize(width: -1, height: 1)] {
                let moved = FixedCaptureOverlay.movedFrame(initial.offsetBy(dx: delta.width, dy: delta.height), reference: initial, within: screen, snap: false)
                XCTAssertEqual(moved.size, size)
                XCTAssertTrue(screen.contains(moved))
                let region = FixedCaptureOverlay.recordingRegion(for: moved, displayID: 42, screenFrame: screen)
                try region.validate(displayID: 42, displaySize: screen.size)
                XCTAssertEqual(try region.appKitFrame(screenFrame: screen), moved)
                XCTAssertEqual(region.displayID, 42)
            }
        }
        let lastPixel = CGRect(x: -1, y: 979, width: 1, height: 1)
        let region = FixedCaptureOverlay.recordingRegion(for: lastPixel, displayID: 42, screenFrame: screen)
        XCTAssertEqual(region.rect, CGRect(x: 1919, y: 0, width: 1, height: 1))
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                        isARepeat: false, keyCode: code)!
    }

    private func makeControls() -> FixedCaptureControlsView {
        _ = NSApplication.shared
        let controls = FixedCaptureControlsView(frame: .zero)
        controls.reset(tag: nil, shortcutDescription: "F4")
        controls.setFrameSize(controls.preferredSize)
        controls.onSizeChange = { [weak controls] in
            guard let controls else { return }
            controls.setFrameSize(controls.preferredSize)
        }
        XCTAssertNil(controls.window)
        return controls
    }

    private func control<T: NSView>(_ id: String, in view: NSView) throws -> T {
        try XCTUnwrap(find(id, in: view) as? T, "Missing control: \(id)")
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id || view.accessibilityIdentifier() == id { return view }
        for child in view.subviews {
            if let found = find(id, in: child) { return found }
        }
        return nil
    }
}
