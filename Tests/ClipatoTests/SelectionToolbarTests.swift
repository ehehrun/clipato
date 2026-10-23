import AppKit
import XCTest
@testable import Clipato

@MainActor
final class SelectionToolbarTests: XCTestCase {
    func testLanguageRefreshPreservesSelectionMarkupAndActiveTextEditor() throws {
        let view = try makeView(tag: .purple)
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 130, y: 110), to: CGPoint(x: 250, y: 210), in: view)
        let annotations = view.annotations
        let region = view.selection
        try press("text", in: view)
        click(CGPoint(x: 330, y: 140), in: view)
        let editor: AnnotationTextEditor = try control("annotation-text-input", in: view)
        editor.string = "保留用户输入 / Keep my text"
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        NotificationCenter.default.post(name: .clipatoLanguageDidChange, object: nil)

        XCTAssertEqual(view.selection, region)
        XCTAssertEqual(view.annotations, annotations)
        XCTAssertEqual(view.assetTag, .purple)
        XCTAssertTrue(find("annotation-text-input", in: view) === editor)
        XCTAssertEqual(editor.string, "保留用户输入 / Keep my text")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
        let fontSize: NSPopUpButton = try control("annotation-font-size", in: view)
        XCTAssertFalse(fontSize.isHidden)
        try assertToolbarFits(in: view)
        XCTAssertNil(view.window)
    }

    func testScreenshotFontSizeAppearsOnlyForTextAndCollapsesWithoutLosingItsValue() throws {
        let view = try makeView()
        let fontSize: NSPopUpButton = try control("annotation-font-size", in: view)
        let toolbar: NSView = try control("selection-toolbar", in: view)
        XCTAssertTrue(fontSize.isHidden)
        XCTAssertEqual(toolbar.frame.height, 38)
        let collapsedWidth = toolbar.frame.width
        try assertToolbarFits(in: view)

        try press("text", in: view)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(fontSize.isHidden)
        XCTAssertTrue(fontSize.isEnabled)
        XCTAssertEqual(fontSize.controlSize, .small)
        XCTAssertEqual(fontSize.frame.width, 64)
        XCTAssertGreaterThan(toolbar.frame.width, collapsedWidth + 60)
        fontSize.selectItem(withTitle: "96 pt")
        send(fontSize)
        try assertToolbarFits(in: view)

        try press("rectangle", in: view)
        XCTAssertTrue(fontSize.isHidden)
        XCTAssertEqual(toolbar.frame.width, collapsedWidth)
        try press("text", in: view)
        XCTAssertEqual(fontSize.titleOfSelectedItem, "96 pt")
        let text: NSButton = try control("text", in: view)
        let mosaic: NSButton = try control("mosaic", in: view)
        XCTAssertTrue(text.image === AnnotationTool.text.image)
        XCTAssertTrue(mosaic.image === AnnotationTool.mosaic.image)
        XCTAssertNil(view.window)
    }

    func testAllToolbarModesKeepCompactControlsInsideTheirBoundsAfterLanguageRefresh() throws {
        for mode in [SelectionView.Mode.screenshot(allowsDestinationActions: true), .screenshot(allowsDestinationActions: false), .recording, .fixedCapture] {
            let view = try makeView(mode: mode, tag: .purple)
            let toolbar: NSView = try control("selection-toolbar", in: view)
            let picker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)
            try assertToolbarFits(in: view)
            XCTAssertEqual(toolbar.frame.height, 38)
            XCTAssertEqual(picker.frame.width, 46)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(picker.menu).minimumWidth, 150)
            XCTAssertEqual(picker.accessibilityValue() as? String, AssetTag.purple.title)
            NotificationCenter.default.post(name: .clipatoLanguageDidChange, object: nil)
            try assertToolbarFits(in: view)
            XCTAssertEqual(picker.assetTag, .purple)
            XCTAssertEqual(picker.accessibilityValue() as? String, AssetTag.purple.title)
            XCTAssertNil(view.window)
        }
    }

    func testFixedRegionToolbarUsesDedicatedStartWithoutRecordingOrMarkupTools() throws {
        let view = try makeView(mode: .fixedCapture, tag: .purple)
        XCTAssertNil(find("recording-mode-picker", in: view))
        XCTAssertNil(find("rectangle", in: view))
        XCTAssertNil(find("text", in: view))
        XCTAssertNil(find("mosaic", in: view))
        XCTAssertNil(find("copy", in: view))
        let start: NSButton = try control("start-fixed-capture", in: view)
        XCTAssertEqual(start.title, "")
        XCTAssertEqual(start.accessibilityLabel(), L("开始连续截图"))
        XCTAssertEqual(start.toolTip, L("开始连续截图"))
        let picker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)
        XCTAssertEqual(picker.assetTag, .purple)
        var selected: CGRect?
        var selectedTag: AssetTag?
        view.onFinish = { [weak view] rect, _ in selected = rect; selectedTag = view!.assetTag }
        start.performClick(nil)
        XCTAssertEqual(selected, view.pixelSelection)
        XCTAssertEqual(selectedTag, .purple)
    }

    func testArrowKeysMoveFixedSelectionInPointsAndClampInsideDisplay() throws {
        let view = try makeView(mode: .fixedCapture)
        let size = view.selection.size
        key(124, in: view)
        key(125, modifiers: .shift, in: view)
        XCTAssertEqual(view.selection.origin, CGPoint(x: 81, y: 70))
        XCTAssertEqual(view.pixelSelection.origin, CGPoint(x: 162, y: 140))
        key(123, modifiers: .shift, in: view)
        key(126, in: view)
        XCTAssertEqual(view.selection.origin, CGPoint(x: 71, y: 69))
        XCTAssertEqual(view.selection.size, size)

        for _ in 0..<10 { key(123, modifiers: .shift, in: view); key(126, modifiers: .shift, in: view) }
        XCTAssertEqual(view.selection.origin, .zero)
        for _ in 0..<40 { key(124, modifiers: .shift, in: view); key(125, modifiers: .shift, in: view) }
        XCTAssertEqual(view.selection.maxX, view.bounds.maxX)
        XCTAssertEqual(view.selection.maxY, view.bounds.maxY)
        XCTAssertEqual(view.selection.size, size)
    }

    func testArrowMovementDoesNotMoveRegionWhileTextEditorIsActive() throws {
        let view = try makeView()
        try press("text", in: view)
        click(CGPoint(x: 130, y: 110), in: view)
        let editor: AnnotationTextEditor = try control("annotation-text-input", in: view)
        editor.string = "编辑中的文字"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let region = view.selection
        key(124, in: view)
        XCTAssertEqual(view.selection, region)
        XCTAssertEqual(editor.string, "编辑中的文字")
        XCTAssertTrue(find("annotation-text-input", in: view) === editor)
    }

    func testNativeTagPickerOnlyNotifiesForUserActionsAndProvidesColorSwatches() {
        _ = NSApplication.shared
        let picker = NativeAssetTagPicker()
        var changes: [AssetTag?] = []
        picker.onChange = { changes.append($0) }
        XCTAssertNil(picker.assetTag)
        picker.assetTag = .purple
        XCTAssertEqual(picker.titleOfSelectedItem, AssetTag.purple.title)
        XCTAssertEqual(picker.accessibilityValue() as? String, AssetTag.purple.title)
        XCTAssertTrue(changes.isEmpty)

        for tag in AssetTag.allCases {
            picker.selectItem(withTitle: tag.title)
            send(picker)
            XCTAssertEqual(picker.assetTag, tag)
            XCTAssertEqual(picker.accessibilityValue() as? String, tag.title)
            XCTAssertNotNil(picker.selectedItem?.image)
        }
        picker.selectItem(withTitle: L("无标签"))
        send(picker)
        XCTAssertNil(picker.assetTag)
        XCTAssertEqual(picker.accessibilityValue() as? String, L("无标签"))
        XCTAssertEqual(changes, AssetTag.allCases.map(Optional.some) + [nil])

        picker.isEnabled = false
        picker.selectItem(withTitle: AssetTag.red.title)
        send(picker)
        XCTAssertEqual(changes.count, AssetTag.allCases.count + 1)
    }

    func testScreenshotTagChangesPreserveMarkupAndOnlySaveFinishesSelection() throws {
        let view = try makeView(tag: .red)
        let originalRegion = view.selection
        try press("rectangle", in: view)
        drag(from: CGPoint(x: 130, y: 110), to: CGPoint(x: 250, y: 210), in: view)
        let originals = view.annotations
        XCTAssertEqual(originals.count, 1)
        let picker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)
        XCTAssertEqual(picker.assetTag, .red)
        var finishedTags: [AssetTag?] = []
        view.onFinish = { [weak view] _, _ in finishedTags.append(view!.assetTag) }

        picker.selectItem(withTitle: AssetTag.blue.title)
        send(picker)
        XCTAssertEqual(view.assetTag, .blue)
        XCTAssertEqual(view.selection, originalRegion)
        XCTAssertEqual(view.annotations, originals)
        XCTAssertTrue(finishedTags.isEmpty)
        let toolbar: NSView = try control("selection-toolbar", in: view)
        click(CGPoint(x: toolbar.frame.minX + 1, y: toolbar.frame.minY + 1), in: view)
        XCTAssertEqual(view.selection, originalRegion)
        XCTAssertEqual(view.annotations, originals)
        XCTAssertTrue(finishedTags.isEmpty)

        try press("save", in: view)
        XCTAssertEqual(finishedTags, [.blue])
    }

    func testRecordingTagCanBeChangedAndClearedBeforeStarting() throws {
        let view = try makeView(mode: .recording, recordingMode: .video, tag: .green)
        let region = view.pixelSelection
        let picker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)
        var completions = 0
        var finishedTag: AssetTag? = .red
        view.onFinish = { [weak view] rect, _ in
            completions += 1
            finishedTag = view!.assetTag
            XCTAssertEqual(rect, region)
        }

        XCTAssertEqual(picker.assetTag, .green)
        picker.selectItem(withTitle: AssetTag.orange.title)
        send(picker)
        XCTAssertEqual(view.assetTag, .orange)
        picker.selectItem(withTitle: L("无标签"))
        send(picker)
        XCTAssertNil(view.assetTag)
        XCTAssertEqual(view.recordingMode, .video)
        XCTAssertEqual(view.pixelSelection, region)
        XCTAssertEqual(completions, 0)

        try press("start", in: view)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(finishedTag)
    }

    func testTagPickerCanBeHiddenWithoutChangingProvidedTag() throws {
        let view = try makeView(mode: .screenshot(allowsDestinationActions: false), tag: .orange, allowsTagSelection: false)
        XCTAssertNil(find("selection-tag-picker", in: view))
        XCTAssertEqual(view.assetTag, .orange)
        var savedTag: AssetTag?
        view.onFinish = { [weak view] _, _ in savedTag = view!.assetTag }
        try press("copy", in: view)
        XCTAssertEqual(savedTag, .orange)
    }

    func testTagSelectionKeepsUnfinishedTextUntilScreenshotCompletes() throws {
        let view = try makeView()
        try press("text", in: view)
        click(CGPoint(x: 130, y: 110), in: view)
        let editor: AnnotationTextEditor = try control("annotation-text-input", in: view)
        editor.string = "标签不会改动这段标注"
        editor.textDidChange(Notification(name: NSText.didChangeNotification))
        let picker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)

        picker.selectItem(withTitle: AssetTag.yellow.title)
        send(picker)

        XCTAssertEqual(view.assetTag, .yellow)
        XCTAssertTrue(find("annotation-text-input", in: view) === editor)
        XCTAssertEqual(editor.string, "标签不会改动这段标注")
        XCTAssertTrue(view.annotations.isEmpty)
        try press("copy", in: view)
        XCTAssertEqual(view.annotations.first?.text, "标签不会改动这段标注")
        XCTAssertNil(find("annotation-text-input", in: view))
    }

    func testRecordingPickerReflectsInitialModeAndIsAbsentFromScreenshotToolbar() throws {
        for mode in RecordingMode.allCases {
            let view = try makeView(mode: .recording, recordingMode: mode)
            let picker: NSSegmentedControl = try control("recording-mode-picker", in: view)
            XCTAssertEqual(view.recordingMode, mode)
            XCTAssertEqual(picker.accessibilityValue() as? String, mode.toolbarTitle)
            XCTAssertEqual(picker.controlSize, .small)
            XCTAssertEqual(picker.frame.height, 28)
            XCTAssertLessThanOrEqual(picker.frame.width, 72)
            for (index, segmentMode) in RecordingMode.allCases.enumerated() {
                XCTAssertEqual(picker.label(forSegment: index), "")
                XCTAssertNotNil(picker.image(forSegment: index))
                XCTAssertEqual(picker.toolTip(forSegment: index), segmentMode.toolbarTitle)
            }
            let start: NSButton = try control("start", in: view)
            XCTAssertEqual(start.title, "")
            XCTAssertEqual(start.accessibilityLabel(), L("开始录屏"))
        }
        let screenshot = try makeView()
        XCTAssertNil(find("recording-mode-picker", in: screenshot))
        XCTAssertNotNil(find("mosaic", in: screenshot))
    }

    func testRecordingModeIconsKeepSelectionAndLocalizedDescriptionsAcrossLanguages() throws {
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
        let view = try makeView(mode: .recording, recordingMode: .video, tag: .purple)
        let region = view.selection
        var changes = 0
        view.onRecordingModeChange = { _ in changes += 1 }
        for language in AppLanguage.allCases where language != .system {
            settings.setLanguage(language)
            let picker: NSSegmentedControl = try control("recording-mode-picker", in: view)
            XCTAssertEqual(view.recordingMode, .video, language.rawValue)
            XCTAssertEqual(view.selection, region, language.rawValue)
            XCTAssertEqual(view.assetTag, .purple, language.rawValue)
            let tagPicker: NativeAssetTagPicker = try control("selection-tag-picker", in: view)
            XCTAssertEqual(tagPicker.accessibilityValue() as? String, AssetTag.purple.title, language.rawValue)
            XCTAssertEqual(tagPicker.frame.width, 46, language.rawValue)
            XCTAssertEqual(picker.selectedSegment, RecordingMode.allCases.firstIndex(of: .video), language.rawValue)
            XCTAssertEqual(picker.accessibilityValue() as? String, RecordingMode.video.toolbarTitle, language.rawValue)
            for (index, mode) in RecordingMode.allCases.enumerated() {
                XCTAssertEqual(picker.label(forSegment: index), "", language.rawValue)
                XCTAssertNotNil(picker.image(forSegment: index), language.rawValue)
                XCTAssertEqual(picker.toolTip(forSegment: index), mode.toolbarTitle, language.rawValue)
            }
            XCTAssertEqual(picker.frame.height, 28, language.rawValue)
            XCTAssertLessThanOrEqual(picker.frame.width, 72, language.rawValue)
            try assertToolbarFits(in: view)
        }
        XCTAssertEqual(changes, 0)
    }

    func testChangingRecordingModePreservesRegionAndOnlyStartCompletesSelection() throws {
        let view = try makeView(mode: .recording)
        let region = view.selection
        let crop = view.pixelSelection
        let picker: NSSegmentedControl = try control("recording-mode-picker", in: view)
        var changes: [RecordingMode] = []
        var finishedModes: [RecordingMode] = []
        var finishedRegions: [CGRect?] = []
        view.onRecordingModeChange = { changes.append($0) }
        view.onFinish = { [weak view] rect, _ in
            finishedModes.append(view!.recordingMode)
            finishedRegions.append(rect)
        }

        picker.selectedSegment = RecordingMode.allCases.firstIndex(of: .video)!
        send(picker)
        XCTAssertEqual(changes, [.video])
        XCTAssertEqual(view.recordingMode, .video)
        XCTAssertEqual(picker.accessibilityValue() as? String, RecordingMode.video.toolbarTitle)
        XCTAssertEqual(view.selection, region)
        XCTAssertEqual(view.pixelSelection, crop)
        XCTAssertTrue(finishedModes.isEmpty)

        try press("start", in: view)
        XCTAssertEqual(finishedModes, [.video])
        XCTAssertEqual(finishedRegions, [crop])
        try press("start", in: view)
        XCTAssertEqual(finishedModes.count, 1)
    }

    func testRecordingModeSynchronizationUpdatesOtherScreenWithoutCallbackLoop() throws {
        let first = try makeView(mode: .recording)
        let second = try makeView(mode: .recording)
        let original = second.selection
        var firstChanges = 0
        var secondChanges = 0
        first.onRecordingModeChange = { mode in firstChanges += 1; second.setRecordingMode(mode) }
        second.onRecordingModeChange = { _ in secondChanges += 1 }
        let picker: NSSegmentedControl = try control("recording-mode-picker", in: first)
        picker.selectedSegment = RecordingMode.allCases.firstIndex(of: .video)!
        send(picker)

        let secondPicker: NSSegmentedControl = try control("recording-mode-picker", in: second)
        XCTAssertEqual(firstChanges, 1)
        XCTAssertEqual(secondChanges, 0)
        XCTAssertEqual(second.recordingMode, .video)
        XCTAssertEqual(secondPicker.selectedSegment, RecordingMode.allCases.firstIndex(of: .video))
        XCTAssertEqual(secondPicker.accessibilityValue() as? String, RecordingMode.video.toolbarTitle)
        XCTAssertEqual(second.selection, original)
        second.setRecordingMode(.keyframes)
        XCTAssertEqual(secondChanges, 0)
        XCTAssertEqual(secondPicker.selectedSegment, RecordingMode.allCases.firstIndex(of: .keyframes))
        XCTAssertEqual(secondPicker.accessibilityValue() as? String, RecordingMode.keyframes.toolbarTitle)
    }

    func testMosaicOptionsBlankSpaceKeepsSelectionAndDrawingHistory() throws {
        let view = try makeView()
        let region = view.selection
        try press("mosaic", in: view)
        click(CGPoint(x: 130, y: 110), in: view)
        let originals = view.annotations
        var finished = false
        view.onFinish = { _, _ in finished = true }
        let options: NSView = try control("mosaic-options", in: view)
        let color: NSButton = try control("color", in: view)
        XCTAssertFalse(options.isHidden)
        XCTAssertFalse(color.isEnabled)

        click(CGPoint(x: options.frame.minX + 1, y: options.frame.minY + 1), in: view)
        XCTAssertEqual(view.selection, region)
        XCTAssertEqual(view.annotations, originals)
        XCTAssertFalse(finished)
        XCTAssertFalse(options.isHidden)
        try press("undo", in: view)
        XCTAssertTrue(view.annotations.isEmpty)
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, originals)
    }

    func testMosaicDotUsesSourcePixelBrushWidthAndIndependentBlockSize() throws {
        let view = try makeView()
        try press("mosaic", in: view)
        let brush: NSPopUpButton = try control("mosaic-brush-size", in: view)
        let blocks: NSPopUpButton = try control("mosaic-block-size", in: view)
        brush.selectItem(withTitle: "48 pt")
        send(brush)
        blocks.selectItem(withTitle: "24 px")
        send(blocks)
        click(CGPoint(x: 130, y: 110), in: view)

        XCTAssertEqual(view.annotations.count, 1)
        let dot = try XCTUnwrap(view.annotations.first)
        XCTAssertEqual(dot.tool, .mosaic)
        XCTAssertEqual(dot.mosaicShape, .brush)
        XCTAssertEqual(dot.width, 96)
        XCTAssertEqual(dot.mosaicSize, 24)
        XCTAssertTrue(dot.isDrawable)
        XCTAssertTrue(dot.points.allSatisfy { $0 == CGPoint(x: 100, y: 100) })
        XCTAssertEqual(dot.mosaicMask.boundingBoxOfPath, CGRect(x: 52, y: 52, width: 96, height: 96))
    }

    func testMosaicShapePickerSwitchesBetweenRectangleAndBrush() throws {
        let view = try makeView()
        try press("mosaic", in: view)
        let shape: NSSegmentedControl = try control("mosaic-shape", in: view)
        let brush: NSPopUpButton = try control("mosaic-brush-size", in: view)
        shape.selectedSegment = MosaicShape.allCases.firstIndex(of: .rectangle)!
        send(shape)
        XCTAssertFalse(brush.isEnabled)
        drag(from: CGPoint(x: 130, y: 110), to: CGPoint(x: 250, y: 200), in: view)
        XCTAssertEqual(view.annotations.count, 1)
        let rectangle = try XCTUnwrap(view.annotations.first)
        XCTAssertEqual(rectangle.mosaicShape, .rectangle)
        XCTAssertEqual(rectangle.mosaicMask.boundingBoxOfPath, CGRect(x: 100, y: 100, width: 240, height: 180))
        click(CGPoint(x: 500, y: 200), in: view)
        XCTAssertEqual(view.annotations.count, 1, "A zero-area rectangle must not add an invisible annotation")

        shape.selectedSegment = MosaicShape.allCases.firstIndex(of: .brush)!
        send(shape)
        XCTAssertTrue(brush.isEnabled)
        click(CGPoint(x: 500, y: 200), in: view)
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.annotations.last?.mosaicShape, .brush)
        XCTAssertTrue(try XCTUnwrap(view.annotations.last).isDrawable)
    }

    func testMosaicCanPaintOverExistingStrokeWithoutSelectingOrFinishingCapture() throws {
        let view = try makeView()
        try press("mosaic", in: view)
        let hit = CGPoint(x: 180, y: 150)
        click(hit, in: view)
        let first = try XCTUnwrap(view.annotations.first)
        var finished = false
        view.onFinish = { _, _ in finished = true }
        click(hit, in: view, clicks: 2)
        XCTAssertFalse(finished, "A double click while painting must not copy and finish the screenshot")
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertEqual(view.annotations.first, first)
        delete(in: view)
        XCTAssertEqual(view.annotations.count, 2, "Painting must not implicitly select the earlier redaction")
    }

    func testMoveModeCannotSelectMosaicAndUndoRedoPreservesStrokeOrder() throws {
        let view = try makeView()
        let region = view.selection
        try press("mosaic", in: view)
        click(CGPoint(x: 130, y: 110), in: view)
        drag(from: CGPoint(x: 350, y: 200), to: CGPoint(x: 450, y: 300), in: view)
        let originals = view.annotations
        XCTAssertEqual(originals.count, 2)
        try press("move", in: view)
        click(CGPoint(x: 130, y: 110), in: view)
        delete(in: view)
        XCTAssertEqual(view.annotations, originals)
        XCTAssertEqual(view.selection, region)
        try press("undo", in: view)
        XCTAssertEqual(view.annotations, [originals[0]])
        try press("redo", in: view)
        XCTAssertEqual(view.annotations, originals)
    }

    private func makeView(mode: SelectionView.Mode = .screenshot(allowsDestinationActions: true), recordingMode: RecordingMode = .keyframes,
                          tag: AssetTag? = nil, allowsTagSelection: Bool = true) throws -> SelectionView {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let view = SelectionView(image: try XCTUnwrap(context.makeImage()), frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                 mode: mode, recordingMode: recordingMode, tag: tag, allowsTagSelection: allowsTagSelection)
        drag(from: CGPoint(x: 80, y: 60), to: CGPoint(x: 720, y: 440), in: view)
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.window)
        return view
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews {
            if let result = find(id, in: child) { return result }
        }
        return nil
    }

    private func control<T: NSView>(_ id: String, in view: NSView) throws -> T {
        try XCTUnwrap(find(id, in: view) as? T, "Missing control: \(id)")
    }

    private func assertToolbarFits(in view: SelectionView) throws {
        view.layoutSubtreeIfNeeded()
        let toolbar: NSView = try control("selection-toolbar", in: view)
        let stack = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(stack.spacing, 2)
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        let frames = visible.map { toolbar.convert($0.bounds, from: $0) }.sorted { $0.minX < $1.minX }
        for (control, frame) in zip(visible, visible.map { toolbar.convert($0.bounds, from: $0) }) {
            XCTAssertGreaterThanOrEqual(frame.minX, -0.001)
            XCTAssertGreaterThanOrEqual(frame.minY, -0.001)
            XCTAssertLessThanOrEqual(frame.maxX, toolbar.bounds.width + 0.001)
            XCTAssertLessThanOrEqual(frame.maxY, toolbar.bounds.height + 0.001)
            if let button = control as? NSButton, !(button is NSPopUpButton) {
                XCTAssertEqual(frame.size, CGSize(width: 28, height: 28))
                XCTAssertEqual(button.title, "")
                XCTAssertEqual(button.imagePosition, .imageOnly)
                XCTAssertTrue(button.hitTest(button.convert(CGPoint(x: 27.5, y: 14), to: button.superview)) === button)
                XCTAssertNil(button.hitTest(button.convert(CGPoint(x: 28.5, y: 14), to: button.superview)))
            }
        }
        for (previous, current) in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.maxX, current.minX + 0.001)
        }
    }

    private func press(_ id: String, in view: SelectionView) throws {
        let button: NSButton = try control(id, in: view)
        button.performClick(nil)
    }

    private func send(_ control: NSControl) {
        XCTAssertNotNil(control.action)
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in view: SelectionView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                          windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ point: CGPoint, in view: SelectionView, clicks: Int = 1) {
        view.mouseDown(with: event(.leftMouseDown, at: point, in: view, clicks: clicks))
        view.mouseUp(with: event(.leftMouseUp, at: point, in: view, clicks: clicks))
    }

    private func drag(from start: CGPoint, to end: CGPoint, in view: SelectionView) {
        view.mouseDown(with: event(.leftMouseDown, at: start, in: view))
        view.mouseDragged(with: event(.leftMouseDragged, at: end, in: view))
        view.mouseUp(with: event(.leftMouseUp, at: end, in: view))
    }

    private func delete(in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                          isARepeat: false, keyCode: 51)!)
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], in view: SelectionView) {
        view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                          isARepeat: false, keyCode: code)!)
    }
}
