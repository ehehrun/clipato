import AppKit
import XCTest
@testable import Clipato

@MainActor
final class RecordingControlsTests: XCTestCase {
    func testLanguageRefreshPreservesPausedRecordingAndChosenTag() throws {
        let controls = makeControls()
        controls.reset(canStop: true, canPause: true, mode: .video, tag: .purple)
        controls.update(elapsed: 65, frameCount: 8, isPaused: true)
        var pauseRequests = 0
        var tagChanges = 0
        controls.onPause = { pauseRequests += 1 }
        controls.onTagChange = { _ in tagChanges += 1 }

        NotificationCenter.default.post(name: .clipatoLanguageDidChange, object: nil)

        let pause: NSButton = try control("recording-pause", in: controls)
        let mode: NSImageView = try control("recording-mode", in: controls)
        let picker: NativeAssetTagPicker = try control("recording-tag", in: controls)
        XCTAssertNotNil(mode.image)
        XCTAssertEqual(mode.toolTip, RecordingMode.video.toolbarTitle)
        XCTAssertEqual(mode.accessibilityLabel(), RecordingMode.video.toolbarTitle)
        XCTAssertEqual(pause.title, "")
        XCTAssertEqual(pause.accessibilityLabel(), L("继续"))
        XCTAssertEqual(pause.toolTip, L("继续录屏"))
        XCTAssertTrue(pause.isEnabled)
        XCTAssertEqual(picker.assetTag, .purple)
        XCTAssertEqual(tagChanges, 0)
        pause.performClick(nil)
        XCTAssertEqual(pauseRequests, 1)
        XCTAssertNil(controls.window)
    }

    func testToolbarSitsBelowSelectedRegion() {
        let visible = CGRect(x: 0, y: 40, width: 1400, height: 800)
        let region = CGRect(x: 300, y: 300, width: 500, height: 300)
        let toolbar = RecordingRegionOverlay.controlsFrame(for: region, within: visible)
        XCTAssertTrue(visible.contains(toolbar))
        XCTAssertEqual(toolbar.midX, region.midX)
        XCTAssertEqual(toolbar.maxY, region.minY - 10)
    }

    func testToolbarMovesAboveWhenSelectionTouchesBottom() {
        let visible = CGRect(x: 0, y: 40, width: 1400, height: 800)
        let region = CGRect(x: 300, y: 40, width: 500, height: 300)
        let toolbar = RecordingRegionOverlay.controlsFrame(for: region, within: visible)
        XCTAssertTrue(visible.contains(toolbar))
        XCTAssertEqual(toolbar.minY, region.maxY + 10)
    }

    func testToolbarStaysVisibleAtAllEdgesAndNegativeDisplayOrigins() {
        let visible = CGRect(x: -1600, y: -280, width: 1600, height: 950)
        for region in [
            CGRect(x: -1600, y: -280, width: 50, height: 50),
            CGRect(x: -50, y: -280, width: 50, height: 50),
            CGRect(x: -1600, y: 620, width: 50, height: 50),
            CGRect(x: -50, y: 620, width: 50, height: 50),
            CGRect(x: -1600, y: -300, width: 1600, height: 1000)
        ] {
            let toolbar = RecordingRegionOverlay.controlsFrame(for: region, within: visible)
            XCTAssertTrue(visible.contains(toolbar), "Toolbar must be inside usable screen bounds for \(region)")
        }
    }

    func testPausedControlsKeepStopAvailableAndResumeActionClickable() throws {
        let controls = makeControls()
        let pause: NSButton = try control("recording-pause", in: controls)
        let stop: NSButton = try control("recording-stop", in: controls)
        let status: NSTextField = try control("recording-status", in: controls)
        let metrics: NSTextField = try control("recording-metrics", in: controls)
        var pauseRequests = 0
        var stopRequests = 0
        controls.onPause = { pauseRequests += 1 }
        controls.onStop = { stopRequests += 1 }

        controls.update(elapsed: 65, frameCount: 8, isPaused: true)

        XCTAssertEqual(status.stringValue, L("已暂停"))
        XCTAssertEqual(metrics.stringValue, L("\("01:05") · \(8) 帧"))
        XCTAssertEqual(pause.title, "")
        XCTAssertEqual(pause.accessibilityLabel(), L("继续"))
        XCTAssertEqual(pause.imagePosition, .imageOnly)
        XCTAssertNotNil(pause.image)
        XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(stop.isEnabled)
        pause.performClick(nil)
        stop.performClick(nil)
        XCTAssertEqual(pauseRequests, 1)
        XCTAssertEqual(stopRequests, 1)
    }

    func testTransitionAndStoppingPreventRepeatedActionsAcrossMetricsUpdates() throws {
        let controls = makeControls()
        let pause: NSButton = try control("recording-pause", in: controls)
        let stop: NSButton = try control("recording-stop", in: controls)
        let status: NSTextField = try control("recording-status", in: controls)
        var actionCount = 0
        controls.onPause = { actionCount += 1 }
        controls.onStop = { actionCount += 1 }

        controls.setPauseTransition(true)
        controls.update(elapsed: 8, frameCount: 2, isPaused: true)
        XCTAssertFalse(pause.isEnabled)
        XCTAssertFalse(stop.isEnabled)
        pause.performClick(nil)
        stop.performClick(nil)
        XCTAssertEqual(actionCount, 0)

        controls.setPauseTransition(false)
        XCTAssertTrue(pause.isEnabled)
        XCTAssertTrue(stop.isEnabled)
        XCTAssertEqual(status.stringValue, L("已暂停"))

        controls.setStopping()
        controls.update(elapsed: 8, frameCount: 2, isPaused: true)
        controls.setPauseTransition(false)
        XCTAssertFalse(pause.isEnabled)
        XCTAssertFalse(stop.isEnabled)
        XCTAssertEqual(status.stringValue, L("正在保存…"))

        controls.reset(canStop: true, canPause: false)
        XCTAssertEqual(status.stringValue, L("正在录屏"))
        XCTAssertEqual(pause.title, "")
        XCTAssertEqual(pause.accessibilityLabel(), L("暂停"))
        XCTAssertFalse(pause.isEnabled)
        XCTAssertTrue(stop.isEnabled)
        controls.setPauseTransition(true)
        controls.setPauseTransition(false)
        XCTAssertFalse(pause.isEnabled)
        XCTAssertTrue(stop.isEnabled)
    }

    func testModeIconSurvivesPauseAndResetsForNextRecording() throws {
        let controls = makeControls()
        let icon: NSImageView = try control("recording-mode", in: controls)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.toolTip, RecordingMode.keyframes.toolbarTitle)
        XCTAssertEqual(icon.accessibilityLabel(), RecordingMode.keyframes.toolbarTitle)
        controls.reset(canStop: true, canPause: true, mode: .video)
        controls.update(elapsed: 12, frameCount: 360, isPaused: true)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.toolTip, RecordingMode.video.toolbarTitle)
        XCTAssertEqual(icon.accessibilityLabel(), RecordingMode.video.toolbarTitle)
        controls.setStopping()
        XCTAssertEqual(icon.toolTip, RecordingMode.video.toolbarTitle)
        controls.reset(canStop: true, canPause: true, mode: .keyframes)
        XCTAssertNotNil(icon.image)
        XCTAssertEqual(icon.toolTip, RecordingMode.keyframes.toolbarTitle)
        XCTAssertEqual(icon.accessibilityLabel(), RecordingMode.keyframes.toolbarTitle)
    }

    func testTagPickerLeavesRoomForStatusAndModeIconAcrossAllLanguages() throws {
        let settings = LanguageSettings.shared
        let originalLanguage = settings.language
        let originalResolvedLanguage = settings.resolvedLanguage
        let originalPreference = UserDefaults.standard.object(forKey: "language")
        defer {
            settings.setLanguage(originalLanguage, preferredLanguages: [originalResolvedLanguage.rawValue])
            if let originalPreference {
                UserDefaults.standard.set(originalPreference, forKey: "language")
            } else {
                UserDefaults.standard.removeObject(forKey: "language")
            }
        }
        let controls = makeControls()
        controls.reset(canStop: true, canPause: true, tag: .purple)
        controls.setStopping()
        let status: NSTextField = try control("recording-status", in: controls)
        let mode: NSImageView = try control("recording-mode", in: controls)
        let picker: NativeAssetTagPicker = try control("recording-tag", in: controls)
        let pause: NSButton = try control("recording-pause", in: controls)
        let stop: NSButton = try control("recording-stop", in: controls)
        for language in AppLanguage.allCases where language != .system {
            settings.setLanguage(language)
            controls.setFrameSize(controls.preferredSize)
            controls.layoutSubtreeIfNeeded()

            XCTAssertEqual(status.stringValue, L("正在保存…"), language.rawValue)
            XCTAssertNotNil(mode.image, language.rawValue)
            XCTAssertEqual(mode.toolTip, RecordingMode.keyframes.toolbarTitle, language.rawValue)
            XCTAssertEqual(mode.accessibilityLabel(), RecordingMode.keyframes.toolbarTitle, language.rawValue)
            XCTAssertEqual(pause.title, "", language.rawValue)
            XCTAssertEqual(stop.title, "", language.rawValue)
            XCTAssertEqual(stop.accessibilityLabel(), L("停止并保存"), language.rawValue)
            XCTAssertEqual(stop.toolTip, L("停止录屏并保存录制"), language.rawValue)
            XCTAssertGreaterThanOrEqual(status.frame.width + 0.5, status.intrinsicContentSize.width, language.rawValue)
            XCTAssertEqual(mode.alignmentRect(forFrame: mode.frame).size, CGSize(width: 16, height: 16), language.rawValue)
            XCTAssertEqual(picker.frame.width, 46, language.rawValue)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(picker.menu).minimumWidth, 150, language.rawValue)
            XCTAssertEqual(picker.accessibilityValue() as? String, AssetTag.purple.title, language.rawValue)
            XCTAssertTrue(try XCTUnwrap(picker.toolTip).contains(AssetTag.purple.title), language.rawValue)
            XCTAssertTrue(try XCTUnwrap(picker.toolTip).contains(L("为这次录制设置颜色标签")), language.rawValue)
            XCTAssertGreaterThanOrEqual(pause.frame.width + 0.5, pause.intrinsicContentSize.width, language.rawValue)
            XCTAssertGreaterThanOrEqual(stop.frame.width + 0.5, stop.intrinsicContentSize.width, language.rawValue)
            let tagFrame = controls.convert(picker.bounds, from: picker)
            let pauseFrame = controls.convert(pause.bounds, from: pause)
            let stopFrame = controls.convert(stop.bounds, from: stop)
            XCTAssertEqual(pauseFrame.size, CGSize(width: 28, height: 28), language.rawValue)
            XCTAssertEqual(stopFrame.size, CGSize(width: 28, height: 28), language.rawValue)
            XCTAssertEqual(pause.imagePosition, .imageOnly, language.rawValue)
            XCTAssertEqual(stop.imagePosition, .imageOnly, language.rawValue)
            XCTAssertNotNil(pause.image, language.rawValue)
            XCTAssertNotNil(stop.image, language.rawValue)
            XCTAssertLessThan(tagFrame.maxX, pauseFrame.minX, language.rawValue)
            XCTAssertLessThan(pauseFrame.maxX, stopFrame.minX, language.rawValue)
            XCTAssertTrue(controls.bounds.contains(stopFrame), language.rawValue)
            XCTAssertTrue(controls.bounds.contains(controls.convert(status.bounds, from: status)), language.rawValue)
            XCTAssertTrue(controls.bounds.contains(controls.convert(mode.bounds, from: mode)), language.rawValue)
            if language == .simplifiedChinese {
                XCTAssertLessThan(controls.preferredSize.width, 450)
                XCTAssertLessThanOrEqual(controls.preferredSize.height, 48)
            }
            XCTAssertNil(controls.window)
        }
    }

    func testIconActionsRemainDistinctAndMetricsResizeOnlyWhenNeeded() throws {
        let controls = makeControls()
        let pause: NSButton = try control("recording-pause", in: controls)
        let stop: NSButton = try control("recording-stop", in: controls)
        let metrics: NSTextField = try control("recording-metrics", in: controls)
        var resizes = 0
        controls.onSizeChange = { [weak controls] in
            guard let controls else { return }
            resizes += 1
            controls.setFrameSize(controls.preferredSize)
        }
        controls.update(elapsed: 360_000, frameCount: 1_000_000, isPaused: false)
        controls.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(metrics.frame.width + 0.5, metrics.intrinsicContentSize.width)
        XCTAssertTrue(controls.bounds.contains(controls.convert(metrics.bounds, from: metrics)))
        let afterFirstUpdate = resizes
        controls.update(elapsed: 360_000, frameCount: 1_000_000, isPaused: false)
        XCTAssertEqual(resizes, afterFirstUpdate, "Identical metrics must not keep resizing the floating window.")
        XCTAssertLessThan(controls.convert(pause.bounds, from: pause).maxX,
                          controls.convert(stop.bounds, from: stop).minX)
        XCTAssertTrue(pause.acceptsFirstMouse(for: nil))
        XCTAssertTrue(stop.acceptsFirstMouse(for: nil))
        XCTAssertEqual(pause.accessibilityLabel(), L("暂停"))
        controls.update(elapsed: 360_000, frameCount: 1_000_000, isPaused: true)
        XCTAssertEqual(pause.accessibilityLabel(), L("继续"))
        XCTAssertEqual(pause.toolTip, L("继续录屏"))
        XCTAssertEqual(pause.title, "")
        XCTAssertNil(controls.window)
    }

    func testTagChoiceIsForwardedWhileRecordingAndPaused() throws {
        let controls = makeControls()
        let picker: NativeAssetTagPicker = try control("recording-tag", in: controls)
        var tags: [AssetTag?] = []
        controls.onTagChange = { tags.append($0) }
        controls.reset(canStop: true, canPause: true, tag: .red)
        XCTAssertEqual(picker.assetTag, .red)
        XCTAssertTrue(tags.isEmpty)

        picker.selectItem(withTitle: AssetTag.purple.title)
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(tags, [.purple])

        controls.update(elapsed: 12, frameCount: 4, isPaused: true)
        XCTAssertTrue(picker.isEnabled)
        picker.selectItem(withTitle: AssetTag.green.title)
        picker.sendAction(picker.action, to: picker.target)
        picker.selectItem(withTitle: L("无标签"))
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(tags, [.purple, .green, nil])
    }

    func testStopDisablesTagBeforeInvokingSaveAndKeepsItDisabled() throws {
        let controls = makeControls()
        let picker: NativeAssetTagPicker = try control("recording-tag", in: controls)
        let stop: NSButton = try control("recording-stop", in: controls)
        var stopRequests = 0
        var tagRequests = 0
        controls.onStop = {
            XCTAssertFalse(picker.isEnabled)
            stopRequests += 1
        }
        controls.onTagChange = { _ in tagRequests += 1 }
        stop.performClick(nil)
        XCTAssertEqual(stopRequests, 1)
        controls.update(elapsed: 5, frameCount: 3, isPaused: false)
        controls.setPauseTransition(false)
        XCTAssertFalse(picker.isEnabled)
        picker.selectItem(withTitle: AssetTag.blue.title)
        picker.sendAction(picker.action, to: picker.target)
        XCTAssertEqual(tagRequests, 0)
        stop.performClick(nil)
        XCTAssertEqual(stopRequests, 1)
    }

    func testResetClearsPreviousRecordingTagWithoutPublishingAChange() throws {
        let controls = makeControls()
        let picker: NativeAssetTagPicker = try control("recording-tag", in: controls)
        var tagRequests = 0
        controls.onTagChange = { _ in tagRequests += 1 }
        controls.reset(canStop: true, canPause: true, tag: .orange)
        controls.setStopping()
        controls.reset(canStop: true, canPause: true)
        XCTAssertNil(picker.assetTag)
        XCTAssertTrue(picker.isEnabled)
        XCTAssertEqual(tagRequests, 0)
    }

    private func makeControls() -> RecordingControlsView {
        _ = NSApplication.shared
        let controls = RecordingControlsView(frame: .zero)
        controls.reset(canStop: true, canPause: true)
        controls.setFrameSize(controls.preferredSize)
        controls.onSizeChange = { [weak controls] in
            guard let controls else { return }
            controls.setFrameSize(controls.preferredSize)
        }
        XCTAssertNil(controls.window)
        return controls
    }

    private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        var pending = [view]
        while let next = pending.popLast() {
            if next.accessibilityIdentifier() == identifier {
                return try XCTUnwrap(next as? T)
            }
            pending.append(contentsOf: next.subviews)
        }
        XCTFail("Missing control: \(identifier)")
        throw NSError(domain: "RecordingControlsTests", code: 1)
    }

}
