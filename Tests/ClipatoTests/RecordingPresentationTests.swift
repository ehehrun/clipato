import AppKit
import CoreMedia
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class RecordingPresentationTests: XCTestCase {
    private func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func wait(_ message: String, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while try !condition(), Date() < deadline {
            drainEvents()
            try await Task.sleep(for: .milliseconds(40))
        }
        drainEvents()
        guard try condition() else {
            XCTFail(message)
            throw NSError(domain: "RecordingPresentationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        let matching = (root as? T).map { [$0] } ?? []
        return matching + root.subviews.flatMap { descendants(type, in: $0) }
    }

    private func png(_ host: NSView) throws -> Data {
        host.layoutSubtreeIfNeeded()
        host.needsDisplay = true
        host.displayIfNeeded()
        let result = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: result)
        return try XCTUnwrap(result.representation(using: .png, properties: [:]))
    }

    private func thumbnailPixels(in png: Data) throws -> (blue: Int, green: Int, bands: Int) {
        // Cache display can vend a floating-point backing rep. Inspect the exported PNG
        // in explicit sRGB bytes so this assertion measures the artifact users see.
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        let image = try XCTUnwrap(decoded.cgImage)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                            space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var blue = 0
        var green = 0
        var bands = 0
        var previousRowHasThumbnail = false
        for y in stride(from: 0, to: image.height, by: 4) {
            var thumbnailSamples = 0
            for x in stride(from: 0, to: image.width, by: 4) {
                let offset = y * context.bytesPerRow + x * 4
                let red = Int(bytes[offset])
                let greenValue = Int(bytes[offset + 1])
                let blueValue = Int(bytes[offset + 2])
                if blueValue > 170, blueValue * 2 > red * 3, blueValue * 2 > greenValue * 3 {
                    blue += 1
                    thumbnailSamples += 1
                }
                if greenValue > 170, greenValue * 2 > red * 3, greenValue * 2 > blueValue * 3 {
                    green += 1
                    thumbnailSamples += 1
                }
            }
            let rowHasThumbnail = thumbnailSamples > max(20, image.width / 24)
            if rowHasThumbnail && !previousRowHasThumbnail { bands += 1 }
            previousRowHasThumbnail = rowHasThumbnail
        }
        return (blue, green, bands)
    }

    private func render(_ host: NSView, named name: String) throws {
        try png(host).write(to: URL(fileURLWithPath: "/private/tmp/clipato-recordings-\(name).png"))
    }

    private func makeKeyframeSession(in root: URL, named name: String) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 240, bitsPerComponent: 8,
                                            bytesPerRow: 320 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.05, green: 0.2, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
        try LibraryStore.writePNG(XCTUnwrap(context.makeImage()), to: directory.appendingPathComponent("frame.png"))
        let manifest = KeyframeManifest(id: UUID(), createdAt: Date(), duration: 2, sampleRate: 1,
                                        threshold: 0.025, width: 320, height: 240,
                                        frames: [.init(file: "frame.png", time: 0)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    private func makeVideo(in root: URL) async throws -> URL {
        let directory = root.appendingPathComponent("Video One", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let writer = try VideoRecordingWriter(directory: directory, started: .zero, sampleRate: 30,
                                              width: 64, height: 48, onFrame: { _ in },
                                              onFailure: { error, _ in XCTFail(error.localizedDescription) })
        let frame = try recordingSample(at: 0, color: (0, 245, 10))
        writer.queue.sync { writer.append(frame) }
        let count = try await writer.finish(duration: 2).get()
        XCTAssertEqual(count, 1)
        let url = directory.appendingPathComponent("Movie One.mp4")
        try FileManager.default.moveItem(at: directory.appendingPathComponent("recording.mp4"), to: url)
        return url
    }

    func testNativeRecordingGridRendersThumbnailsAndRetainsSelectionAcrossModesAndResize() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_RECORDING_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_RECORDING_UI_QA=1 to opt into a transparent native recording fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let name = "Clipato.RecordingPresentation.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        let root = library.recordingDirectory
        try makeKeyframeSession(in: root, named: "Keyframes One")
        try makeKeyframeSession(in: root, named: "Keyframes Two")
        try makeKeyframeSession(in: root, named: "Keyframes Three")
        let firstVideo = try await makeVideo(in: root)
        let secondDirectory = root.appendingPathComponent("Video Two", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: false)
        let secondVideo = secondDirectory.appendingPathComponent("Movie Two.mp4")
        try FileManager.default.copyItem(at: firstVideo, to: secondVideo)
        try library.reloadSessions()
        _ = try library.createCollection(name: "Recording Fixture")
        XCTAssertEqual(library.sessions.count, 3)
        XCTAssertEqual(library.videos.count, 2)
        model.section = .recordings
        let appearance = AppearanceSettings.shared
        let originalFontSize = appearance.consoleFontSize
        appearance.setConsoleFontSize(.normal)
        let host = NSHostingView(rootView: RecordingView(model: model, library: library, recorder: model.recorder)
            .defaultAppStorage(defaults).consoleTypography()
            .background(Palette.background).foregroundStyle(Palette.foreground).tint(Palette.accent))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 960, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
            appearance.setConsoleFontSize(originalFontSize)
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }

        func selectionMenus() -> [NSButton] {
            host.layoutSubtreeIfNeeded()
            return descendants(NSButton.self, in: host).filter { button in
                let frame = button.convert(button.bounds, to: host)
                let distanceToBottom = host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY - host.bounds.minY
                return distanceToBottom >= 0 && distanceToBottom < 50
            }
        }
        do {
            try await wait("The default recording overview must display real MP4 and keyframe PNG thumbnails on one row") {
                let pixels = try thumbnailPixels(in: png(host))
                return pixels.blue > 500 && pixels.green > 500 && pixels.bands == 1
            }
        } catch {
            let data = try png(host)
            let pixels = try thumbnailPixels(in: data)
            print("Recording overview timeout: blue=\(pixels.blue), green=\(pixels.green), bands=\(pixels.bands), hostBounds=\(host.bounds)")
            try data.write(to: URL(fileURLWithPath: "/private/tmp/clipato-recordings-overview-timeout.png"))
            throw error
        }
        try await wait("The native collection and tag menus did not materialize") { selectionMenus().count == 2 }
        XCTAssertTrue(selectionMenus().allSatisfy { !$0.isEnabled })
        try render(host, named: "overview-light")

        model.section = .images
        NotificationCenter.default.post(name: .clipatoSelectAllVisibleAssets, object: model)
        drainEvents()
        XCTAssertTrue(selectionMenus().allSatisfy { !$0.isEnabled },
                      "A mounted recording pane must ignore another section's select-all command")
        model.section = .recordings
        NotificationCenter.default.post(name: .clipatoSelectAllVisibleAssets, object: model)
        try await wait("The recording select-all command must enable its native collection and tag menus") {
            let menus = selectionMenus()
            return menus.count == 2 && menus.allSatisfy(\.isEnabled)
        }

        window.setContentSize(CGSize(width: 640, height: 800))
        try await wait("Narrowing the recording pane must reflow the thumbnails into two visible rows") {
            let pixels = try thumbnailPixels(in: png(host))
            return host.bounds.width == 640 && pixels.blue > 500 && pixels.green > 500 && pixels.bands == 2
        }
        XCTAssertTrue(selectionMenus().allSatisfy(\.isEnabled))
        try render(host, named: "overview-narrow-light")

        window.setContentSize(CGSize(width: 960, height: 800))
        defaults.set(VaultDisplayMode.standard.rawValue, forKey: "recordingDisplayMode")
        try await wait("Changing to card mode at the original width must render the larger media cards on two rows") {
            let pixels = try thumbnailPixels(in: png(host))
            return host.bounds.width == 960 && pixels.blue > 500 && pixels.green > 500 && pixels.bands == 2
        }
        XCTAssertTrue(selectionMenus().allSatisfy(\.isEnabled))
        try render(host, named: "cards-light")

        appearance.setConsoleFontSize(.largest)
        window.appearance = NSAppearance(named: .darkAqua)
        let screen = try XCTUnwrap(window.screen)
        let titlebarHeight = window.frame.height - window.contentRect(forFrameRect: window.frame).height
        let contentHeight = screen.visibleFrame.height - titlebarHeight
        window.setContentSize(CGSize(width: 960, height: contentHeight))
        do {
            try await wait("The card grid must retain its thumbnails after changing font size and window height") {
                let pixels = try thumbnailPixels(in: png(host))
                return abs(host.bounds.height - contentHeight) < 1 && pixels.blue > 500 && pixels.green > 500
            }
        } catch {
            let data = try png(host)
            let pixels = try thumbnailPixels(in: data)
            print("Recording dark/20px timeout: blue=\(pixels.blue), green=\(pixels.green), bands=\(pixels.bands), hostBounds=\(host.bounds), expectedContentHeight=\(contentHeight), windowFrame=\(window.frame)")
            try data.write(to: URL(fileURLWithPath: "/private/tmp/clipato-recordings-cards-dark-20px-timeout.png"))
            throw error
        }
        try await Task.sleep(for: .milliseconds(150))
        drainEvents()
        try render(host, named: "cards-dark-20px")
        defaults.set(VaultDisplayMode.imagesOnly.rawValue, forKey: "recordingDisplayMode")
        try await wait("Switching back to overview must retain thumbnails and the existing recording selection") {
            let pixels = try thumbnailPixels(in: png(host))
            let menus = selectionMenus()
            return pixels.blue > 500 && pixels.green > 500 && menus.count == 2 && menus.allSatisfy(\.isEnabled)
        }
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(window.alphaValue, 0)
        print("PASS native recordings: real H.264 and keyframe PNG thumbnails render in overview and card modes; their pixel bands reflow when resized. Native collection/tag menus verify section-scoped select-all and selection retention. Transparent fixture renders saved to /private/tmp/clipato-recordings-*.png. SwiftUI card AX frames, exact selected count, native mouse clicks, and playback windows are not exercised.")
    }

    func testNativeThresholdEditorValidatesPercentagesAndPresetActions() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_RECORDING_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_RECORDING_UI_QA=1 to opt into a transparent native recording fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let name = "Clipato.RecordingThreshold.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        model.recordingMode = .keyframes
        model.threshold = 0.0375
        let appearance = AppearanceSettings.shared
        let originalFontSize = appearance.consoleFontSize
        appearance.setConsoleFontSize(.normal)
        let host = NSHostingView(rootView: Form {
            RecordingSettingsSection(model: model)
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(ExpandedRecordingOptionsFixtureStyle())
        .scrollContentBackground(.hidden)
        .background(Palette.background).foregroundStyle(Palette.foreground).tint(Palette.accent)
        .consoleTypography())
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 820, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
            appearance.setConsoleFontSize(originalFontSize)
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: directory)
        }

        func fields() -> [NSTextField] {
            host.layoutSubtreeIfNeeded()
            return descendants(NSTextField.self, in: host).filter(\.isEditable)
        }
        func beginEditing(_ text: String) throws {
            let field = try XCTUnwrap(fields().first)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        func edit(_ text: String) throws {
            try beginEditing(text)
            _ = window.makeFirstResponder(nil)
            drainEvents()
        }
        let decimal = try XCTUnwrap(LanguageSettings.shared.locale.decimalSeparator)
        let customText = "3\(decimal)75"
        try await wait("An existing custom threshold must create the actual native numeric input") {
            fields().count == 1 && fields()[0].stringValue == customText
        }
        XCTAssertEqual(model.threshold, 0.0375, accuracy: 0.0000001)
        try render(host, named: "threshold-light")

        try edit("0\(decimal)5")
        try await wait("The native percentage input must accept its 0.5% lower boundary") {
            abs(model.threshold - 0.005) < 0.0000001
        }
        for invalid in ["0\(decimal)49", "12\(decimal)01", "invalid"] {
            try edit(invalid)
            try await Task.sleep(for: .milliseconds(80))
            drainEvents()
            XCTAssertEqual(model.threshold, 0.005, accuracy: 0.0000001,
                           "An out-of-range or nonnumeric native edit must not replace the valid threshold: \(invalid)")
        }
        try edit("12")
        try await wait("The native percentage input must accept its 12% upper boundary") {
            abs(model.threshold - 0.12) < 0.0000001
        }

        if descendants(NSSegmentedControl.self, in: host).contains(where: { $0.segmentCount == 4 }) {
            try beginEditing(customText)
            for (index, expected) in [(1, 0.025), (0, 0.01), (2, 0.05)] {
                let picker = try XCTUnwrap(descendants(NSSegmentedControl.self, in: host).first { $0.segmentCount == 4 })
                let action = try XCTUnwrap(picker.action)
                picker.selectedSegment = index
                XCTAssertTrue(picker.sendAction(action, to: picker.target))
                _ = window.makeFirstResponder(nil)
                try await wait("The native preset action must apply the chosen percentage and hide custom input") {
                    abs(model.threshold - expected) < 0.0000001 && fields().isEmpty
                }
            }
            let picker = try XCTUnwrap(descendants(NSSegmentedControl.self, in: host).first { $0.segmentCount == 4 })
            let action = try XCTUnwrap(picker.action)
            picker.selectedSegment = 3
            XCTAssertTrue(picker.sendAction(action, to: picker.target))
            try await wait("The native custom segment must restore an editable field without changing the last preset") {
                fields().count == 1 && abs(model.threshold - 0.05) < 0.0000001
            }
            print("PASS native threshold preset actions: 1%, 2.5%, 5%, and custom use the real NSSegmentedControl target/action; ending an existing custom edit after choosing a preset does not restore the old text.")
        } else {
            print("Native threshold preset mouse/action coverage unavailable: this host does not vend NSSegmentedControl. Numeric field editing remains covered.")
        }

        try edit(customText)
        try await wait("The native custom input must retain two fractional percentage digits") {
            fields().count == 1 && fields()[0].stringValue == customText && abs(model.threshold - 0.0375) < 0.0000001
        }
        appearance.setConsoleFontSize(.largest)
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(150))
        drainEvents()
        try render(host, named: "threshold-dark-20px")
        XCTAssertNil(window.attachedSheet)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(window.alphaValue, 0)
        print("PASS native threshold input: existing 3.75% is displayed; real field-editor commits accept 0.5% and 12%, reject out-of-range and invalid text, and preserve custom precision. Fixture-only expanded advanced content is rendered in light and dark/20px; no SwiftUI AX or physical mouse events are required.")
    }
}

private struct ExpandedRecordingOptionsFixtureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
            configuration.content
        }
    }
}
