import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class ImageProcessingNavigationTests: XCTestCase {
    private func drainEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }

    private func wait(_ message: String, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            drainEvents()
            try await Task.sleep(for: .milliseconds(20))
        }
        drainEvents()
        guard condition() else {
            XCTFail(message)
            throw NSError(domain: "ImageProcessingNavigationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for child in view.subviews { result.append(contentsOf: descendants(type, in: child)) }
        return result
    }

    private func fixtureImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 720, height: 480, bitsPerComponent: 8,
                                            bytesPerRow: 720 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.16, green: 0.38, blue: 0.62, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 720, height: 480))
        context.setFillColor(CGColor(red: 0.96, green: 0.75, blue: 0.32, alpha: 1))
        context.fillEllipse(in: CGRect(x: 220, y: 100, width: 280, height: 280))
        return try XCTUnwrap(context.makeImage())
    }

    private func render(_ host: NSView, to name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/clipato-processing-\(name).png"))
    }

    func testProcessingAndRenameRoutesUseConsoleAndRetainEditableState() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_PROCESSING_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_PROCESSING_UI_QA=1 to opt into a transparent native console fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ProcessingTools.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaultsName = "Clipato.ProcessingTools.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        let image = try fixtureImage()
        let first = try library.addImage(image, source: "截图")
        let second = try library.addImage(image, source: "截图")
        let images = [first, second]
        model.selected = [first.id, second.id]
        model.section = .imageProcessing
        let appearance = AppearanceSettings.shared
        let originalFontSize = appearance.consoleFontSize
        appearance.setConsoleFontSize(.normal)

        let host = NSHostingView(rootView: MainView(model: model))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1020, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            model.dismissImageProcessing()
            window.contentView = nil
            window.close()
            appearance.setConsoleFontSize(originalFontSize)
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: defaultsName)
            try FileManager.default.removeItem(at: directory)
        }

        func editableFields() -> [NSTextField] {
            host.layoutSubtreeIfNeeded()
            return descendants(NSTextField.self, in: host).filter(\.isEditable)
        }
        func enter(_ text: String, in field: NSTextField) {
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification,
                                                              object: field))
        }
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(100))
            drainEvents()
            host.layoutSubtreeIfNeeded()
        }
        func renderAppearances(_ name: String) async throws {
            window.appearance = NSAppearance(named: .aqua)
            appearance.setConsoleFontSize(.normal)
            try await settle()
            try render(host, to: "\(name)-light")
            window.appearance = NSAppearance(named: .darkAqua)
            try await settle()
            try render(host, to: "\(name)-dark")
            appearance.setConsoleFontSize(.largest)
            try await settle()
            try render(host, to: "\(name)-dark-20px")
            window.appearance = NSAppearance(named: .aqua)
            try await settle()
            try render(host, to: "\(name)-light-20px")
            appearance.setConsoleFontSize(.normal)
            try await settle()
        }

        try await settle()
        try await renderAppearances("tools-overview")
        for tool in [ImageTool.compress, .resize, .convert, .grid] {
            model.selectImageProcessing(tool)
            try await settle()
            XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.tool(tool)))
            if tool == .compress { try await renderAppearances("source-selection") }
            model.chooseVaultImageProcessing(.tool(tool))
            try await settle()
            XCTAssertEqual(model.imageProcessingRoute, .toolSelection(tool))
            XCTAssertNil(window.attachedSheet)
            model.prepareImageExport(tool == .grid ? [first] : images, mode: .files, tool: tool)
            try await settle()
            XCTAssertEqual(model.imageProcessingRoute, .processing(tool))
            XCTAssertNil(window.attachedSheet, "Image processing must occupy the console rather than attach a sheet")

            if tool == .compress {
                try await wait("The compression target input did not materialize") {
                    editableFields().contains { $0.stringValue == "500" }
                }
                let target = try XCTUnwrap(editableFields().first { $0.stringValue == "500" })
                enter("640", in: target)
                try await settle()
                for section in [LibrarySection.images, .appearance, .general] {
                    model.section = section
                    try await settle()
                    XCTAssertEqual(model.imageProcessingRoute, .processing(.compress))
                    XCTAssertTrue(editableFields().contains { $0 === target })
                    model.section = .imageProcessing
                    try await settle()
                    XCTAssertTrue(editableFields().contains { $0 === target },
                                  "The native compression field must stay mounted across sidebar navigation")
                    XCTAssertEqual(target.stringValue, "640", "The edited compression target must survive navigation")
                }
                let scroll = try XCTUnwrap(descendants(NSScrollView.self, in: host)
                    .filter { $0.frame.width > host.bounds.width / 2 }
                    .max { $0.frame.height < $1.frame.height })
                let originalHeight = scroll.contentView.bounds.height
                window.setContentSize(NSSize(width: 1250, height: 900))
                try await wait("The processing viewport did not expand with the console window") {
                    host.layoutSubtreeIfNeeded()
                    return scroll.contentView.bounds.height > originalHeight + 150
                }
                XCTAssertTrue(editableFields().contains { $0 === target })
                XCTAssertEqual(target.stringValue, "640")
                window.setContentSize(NSSize(width: 1020, height: 700))
                try await settle()
            }
            try await renderAppearances("tool-\(String(describing: tool))")
            model.returnToImageProcessingInput()
            try await settle()
            XCTAssertEqual(model.imageProcessingRoute, .toolSelection(tool))
            XCTAssertTrue(model.batchExportImages.isEmpty)
            XCTAssertNil(window.attachedSheet)
            model.dismissImageProcessing()
            try await settle()
            XCTAssertNil(model.imageProcessingRoute)
        }

        model.selectBatchRename()
        try await settle()
        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.rename))
        model.chooseVaultImageProcessing(.rename)
        try await settle()
        XCTAssertEqual(model.imageProcessingRoute, .renameSelection)
        XCTAssertNil(window.attachedSheet)
        model.prepareBatchRename(images.map { .image($0.id) })
        try await wait("The rename prefix field did not materialize") {
            editableFields().contains { $0.stringValue == BatchRenameRule().prefix }
        }
        let prefix = try XCTUnwrap(editableFields().first { $0.stringValue == BatchRenameRule().prefix })
        let fieldCount = editableFields().count
        XCTAssertGreaterThanOrEqual(fieldCount, 3)
        enter("Fixture-", in: prefix)
        try await settle()
        XCTAssertEqual(model.imageProcessingRoute, .renamePreview)
        XCTAssertNil(window.attachedSheet)
        for section in [LibrarySection.images, .appearance, .general] {
            model.section = section
            try await settle()
            XCTAssertTrue(editableFields().contains { $0 === prefix })
            model.section = .imageProcessing
            try await settle()
            XCTAssertEqual(editableFields().count, fieldCount)
            XCTAssertTrue(editableFields().contains { $0 === prefix },
                          "The rename prefix must retain its real native control across sidebar navigation")
            XCTAssertEqual(prefix.stringValue, "Fixture-")
        }
        try await renderAppearances("rename")
        model.returnToImageProcessingInput()
        try await settle()
        XCTAssertEqual(model.imageProcessingRoute, .renameSelection)
        XCTAssertTrue(model.batchRenameAssets.isEmpty)
        XCTAssertNil(window.attachedSheet)
        model.dismissImageProcessing()
        try await settle()
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertEqual(window.alphaValue, 0)
        for section in [LibrarySection.appearance, .general] {
            model.section = section
            for (name, mode, size) in [("light", NSAppearance.Name.aqua, ConsoleFontSize.normal),
                                       ("dark-20px", NSAppearance.Name.darkAqua, ConsoleFontSize.allCases.last!)] {
                appearance.setConsoleFontSize(size)
                window.appearance = NSAppearance(named: mode)
                try await settle()
                try render(host, to: "\(section == .appearance ? "appearance" : "settings")-top-\(name)")
                let scroll = try XCTUnwrap(descendants(NSScrollView.self, in: host).max {
                    ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
                })
                let document = try XCTUnwrap(scroll.documentView)
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
                try await settle()
                try render(host, to: "\(section == .appearance ? "appearance" : "settings")-bottom-\(name)")
                XCTAssertTrue(model.canClearLibraryData)
                XCTAssertFalse(model.clearingLibraryData)
                XCTAssertEqual(library.images.count, images.count, "Rendering settings never confirms or executes cleanup")
            }
        }
        print("PASS native tools: four processing tools and rename use console routes without sheets; real editable compression and prefix fields survive sidebar navigation; processing viewport follows window resize. Fixture-only light/dark/20px renders saved to /private/tmp/clipato-processing-*.png. Native button presses and export destinations are not covered by this transparent-host test.")
    }

    func testScanRouteRetainsItsNativeContentAcrossConsoleSections() async throws {
        guard ProcessInfo.processInfo.environment["CLIPATO_PROCESSING_UI_QA"] == "1" else {
            throw XCTSkip("Set CLIPATO_PROCESSING_UI_QA=1 to opt into a transparent native console fixture")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Clipato.ProcessingNavigation.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let defaultsName = "Clipato.ProcessingNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let model = AppModel(root: directory, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        let image = try fixtureImage()
        let first = try library.addImage(image, source: "截图")
        let second = try library.addImage(image, source: "截图")
        let urls = Set([library.imageURL(first), library.imageURL(second)])
        model.selected = [first.id, second.id]
        model.section = .imageProcessing
        let appearance = AppearanceSettings.shared
        let originalFontSize = appearance.consoleFontSize
        appearance.setConsoleFontSize(.normal)

        let host = NSHostingView(rootView: MainView(model: model))
        host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1020, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            model.dismissAssetScan()
            window.contentView = nil
            window.close()
            appearance.setConsoleFontSize(originalFontSize)
            await library.cancelStorageWorkAndWait()
            defaults.removePersistentDomain(forName: defaultsName)
            try FileManager.default.removeItem(at: directory)
        }

        func sources() -> [ImagePreviewSourceView] {
            host.layoutSubtreeIfNeeded()
            return descendants(ImagePreviewSourceView.self, in: host).filter { source in
                source.url.map(urls.contains) == true && source.image != nil
            }
        }
        func resultSources() -> [ImagePreviewSourceView] {
            sources().filter { $0.bounds.width > 0 && $0.bounds.width <= 100 }
        }
        try await Task.sleep(for: .milliseconds(100))
        drainEvents()
        try render(host, to: "overview-light")

        // Invoke the same model actions as the route controls; no synthetic input or AX activation is needed.
        model.selectAssetScan(.duplicates)
        XCTAssertEqual(model.imageProcessingRoute, .sourceSelection(.scan(.duplicates)))
        model.chooseVaultImageProcessing(.scan(.duplicates))
        try await Task.sleep(for: .milliseconds(100))
        drainEvents()
        XCTAssertEqual(model.imageProcessingRoute, .scanSelection)
        XCTAssertNil(window.attachedSheet)
        try render(host, to: "picker-light")

        model.prepareAssetScan([.image(first.id), .image(second.id)], mode: .duplicates)
        await Task.yield()
        drainEvents()
        host.layoutSubtreeIfNeeded()
        try render(host, to: "results-initial")
        try await wait("The real duplicate scan did not materialize both result thumbnails") { resultSources().count == 2 }
        XCTAssertEqual(model.imageProcessingRoute, .scanResults)
        XCTAssertNil(window.attachedSheet, "The scan must fill the console rather than attach a sheet")
        let retainedViews = resultSources()
        let retainedSources = Set(retainedViews.map(ObjectIdentifier.init))
        XCTAssertEqual(Set(resultSources().compactMap(\.url)), urls)
        try render(host, to: "results-light")

        for section in [LibrarySection.images, .appearance, .general] {
            model.section = section
            try await Task.sleep(for: .milliseconds(100))
            drainEvents()
            XCTAssertEqual(model.imageProcessingRoute, .scanResults)
            XCTAssertTrue(retainedSources.isSubset(of: Set(resultSources().map(ObjectIdentifier.init))),
                          "Browsing another section must keep the active result views mounted")
            model.section = .imageProcessing
            try await Task.sleep(for: .milliseconds(100))
            drainEvents()
            XCTAssertEqual(Set(resultSources().map(ObjectIdentifier.init)), retainedSources,
                           "Returning must reuse the existing native result views, without remounting their scan")
            XCTAssertTrue(retainedViews.allSatisfy { $0.superview != nil })
        }

        let resultsScroll = try XCTUnwrap(descendants(NSScrollView.self, in: host)
            .first { $0.frame.width > host.bounds.width / 2 })
        let originalResultsHeight = resultsScroll.contentView.bounds.height
        window.setContentSize(NSSize(width: 1250, height: 900))
        try await wait("The results viewport did not expand with the console window") {
            host.layoutSubtreeIfNeeded()
            return resultsScroll.contentView.bounds.height > originalResultsHeight + 150
        }
        XCTAssertEqual(Set(resultSources().map(ObjectIdentifier.init)), retainedSources)
        window.setContentSize(NSSize(width: 1020, height: 700))
        try await Task.sleep(for: .milliseconds(50))
        drainEvents()
        window.appearance = NSAppearance(named: .darkAqua)
        try render(host, to: "results-dark")
        appearance.setConsoleFontSize(.largest)
        try await Task.sleep(for: .milliseconds(50))
        drainEvents()
        try render(host, to: "results-dark-20px")
        window.appearance = NSAppearance(named: .aqua)
        try render(host, to: "results-light-20px")
        appearance.setConsoleFontSize(.normal)

        model.returnToImageProcessingInput()
        try await Task.sleep(for: .milliseconds(100))
        drainEvents()
        try render(host, to: "picker-return")
        XCTAssertEqual(model.imageProcessingRoute, .scanSelection)
        XCTAssertTrue(resultSources().isEmpty, "Returning to inputs must release the previous result rows")
        XCTAssertTrue(model.scanAssets.isEmpty, "Returning to inputs must revoke the previous deletion scope")
        XCTAssertNil(window.attachedSheet)
        model.dismissAssetScan()
        try await wait("Returning to the tool overview did not release the picker") { sources().isEmpty }
        XCTAssertNil(model.imageProcessingRoute)
        XCTAssertTrue(model.scanAssets.isEmpty)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(window.alphaValue, 0)
        print("PASS native route host: model actions mount picker and real duplicate results without sheets; source view identities survive sidebar changes; results viewport grows with console; returning releases prior scope. Fixture-only light/dark renders saved to /private/tmp/clipato-processing-*.png. Native button presses are not covered by this transparent-host test.")
    }
}
