import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

@MainActor
final class GIFRecordingIntegrationTests: XCTestCase {
    func testCompletionKeepsAnimatedGIFInVaultAndCopiesTheSameBytesAndFileURL() async throws {
        let (model, defaults, pasteboard) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let directory = try model.prepareGIFRecording()
        let input = directory.appendingPathComponent("recording.gif")
        try writeGIF(to: input)
        let bytes = try Data(contentsOf: input)
        model.recordingRegion = RecordingRegion(displayID: 42, rect: CGRect(x: 10, y: 20, width: 8, height: 6))
        var completions: [(String, CGDirectDisplayID?)] = []
        var directoryExistedWhenPublished: [Bool] = []
        let subscription = model.recordingCompletion.sink {
            completions.append(($0.message, $0.displayID))
            directoryExistedWhenPublished.append(FileManager.default.fileExists(atPath: directory.path))
        }
        defer { subscription.cancel() }

        try model.finishGIFRecording(at: input, pasteboard: pasteboard)

        let item = try XCTUnwrap(library.images.first)
        let output = library.imageURL(item)
        XCTAssertEqual(item.filename, "GIF-001.gif")
        XCTAssertEqual(item.source, "GIF 录制")
        XCTAssertEqual(item.width, 8)
        XCTAssertEqual(item.height, 6)
        XCTAssertEqual(model.section, .images)
        XCTAssertEqual(model.selected, [item.id])
        XCTAssertEqual(model.notice, L("GIF 已保存到保管箱，并复制到剪贴板"))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first?.0, model.notice)
        XCTAssertEqual(completions.first?.1, 42)
        XCTAssertEqual(directoryExistedWhenPublished, [false])
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 2)
        XCTAssertEqual(try library.recentImage(), item)
        XCTAssertEqual(try Data(contentsOf: output), bytes)
        XCTAssertEqual(pasteboard.data(forType: gifType), bytes)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), output.absoluteString)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 1, nil))
        await library.cancelStorageWorkAndWait()
        let reopened = try LibraryStore(root: library.root, defaults: defaults, enforceStorageQuota: false)
        addTeardownBlock { await reopened.cancelStorageWorkAndWait() }
        XCTAssertEqual(try reopened.recentImage(), item)
        XCTAssertEqual(try Data(contentsOf: reopened.imageURL(item)), bytes)
    }

    func testUnreadableRecordingPreservesVaultHistoryAndClipboardAndCleansItsTemporaryDirectory() throws {
        let (model, _, pasteboard) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let original = try library.addImage(pixels(gray: 0.5), source: "截图")
        let directory = try model.prepareGIFRecording()
        let input = directory.appendingPathComponent("recording.gif")
        try Data("not a GIF".utf8).write(to: input)
        pasteboard.setString("keep clipboard", forType: .string)
        let files = try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted()
        var completions = 0
        let subscription = model.recordingCompletion.sink { _ in completions += 1 }
        defer { subscription.cancel() }

        XCTAssertThrowsError(try model.finishGIFRecording(at: input, pasteboard: pasteboard))

        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep clipboard")
        XCTAssertEqual(completions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted(), files)
    }

    func testPrivacyModeCopiesGIFWithoutSavingMediaHistoryNamesOrSelection() throws {
        let (model, defaults, pasteboard) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let original = try library.addImage(pixels(gray: 0.5), source: "截图")
        let originalBytes = try Data(contentsOf: library.imageURL(original))
        model.selected = [original.id]
        model.section = .recordings
        model.privacyMode = true
        let images = try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted()
        let recordings = try FileManager.default.subpathsOfDirectory(atPath: library.recordingDirectory.path).sorted()
        let index = try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults)
        let directory = try model.prepareGIFRecording()
        XCTAssertFalse(directory.standardizedFileURL.path.hasPrefix(library.root.standardizedFileURL.path + "/"))
        let input = directory.appendingPathComponent("recording.gif")
        try writeGIF(to: input)
        let bytes = try Data(contentsOf: input)
        pasteboard.setString("file:///prior.gif", forType: .fileURL)
        var completions: [String] = []
        var directoryExistedWhenPublished: [Bool] = []
        let subscription = model.recordingCompletion.sink {
            completions.append($0.message)
            directoryExistedWhenPublished.append(FileManager.default.fileExists(atPath: directory.path))
        }
        defer { subscription.cancel() }

        try model.finishGIFRecording(at: input, pasteboard: pasteboard)

        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try Data(contentsOf: library.imageURL(original)), originalBytes)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: library.screenshotDirectory.path).sorted(), images)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: library.recordingDirectory.path).sorted(), recordings)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), index)
        XCTAssertEqual(model.selected, [original.id])
        XCTAssertEqual(model.section, .recordings)
        XCTAssertEqual(pasteboard.data(forType: gifType), bytes)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertEqual(model.notice, L("GIF 已复制到剪贴板，未保存到保管箱"))
        XCTAssertEqual(completions, [L("GIF 已复制到剪贴板，未保存到保管箱")])
        XCTAssertEqual(directoryExistedWhenPublished, [false])
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let copied = try XCTUnwrap(pasteboard.data(forType: gifType))
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(copied as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(decoded), 2)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(decoded, 1, nil))
    }

    func testPrivateGIFWorksWithoutAnAvailableVault() throws {
        let (model, defaults, pasteboard) = try makeModel()
        model.privacyMode = true
        model.library = nil
        let directory = try model.prepareGIFRecording()
        let input = directory.appendingPathComponent("recording.gif")
        try writeGIF(to: input)
        let bytes = try Data(contentsOf: input)

        try model.finishGIFRecording(at: input, pasteboard: pasteboard)

        XCTAssertEqual(pasteboard.data(forType: gifType), bytes)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertNil(model.library)
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 1)
    }

    func testEnablingThenDisablingPrivacyDuringARecordingKeepsThatGIFPrivateAndResetsForTheNextSession() throws {
        let (model, defaults, pasteboard) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let first = try model.prepareGIFRecording()
        let firstInput = first.appendingPathComponent("recording.gif")
        try writeGIF(to: firstInput)
        let privateBytes = try Data(contentsOf: firstInput)
        model.privacyMode = true
        model.privacyMode = false

        try model.finishGIFRecording(at: firstInput, pasteboard: pasteboard)

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertNil(try library.recentImage())
        XCTAssertEqual(pasteboard.data(forType: gifType), privateBytes)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        let second = try model.prepareGIFRecording()
        XCTAssertNotEqual(first, second)
        let secondInput = second.appendingPathComponent("recording.gif")
        try writeGIF(to: secondInput)
        try model.finishGIFRecording(at: secondInput, pasteboard: pasteboard)

        let saved = try XCTUnwrap(library.images.first)
        XCTAssertEqual(saved.filename, "GIF-001.gif")
        XCTAssertEqual(try library.recentImage(), saved)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), library.imageURL(saved).absoluteString)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testTurningOffPrivacyBeforeFinishingDoesNotPersistAPrivateSession() throws {
        let (model, defaults, pasteboard) = try makeModel()
        let library = try XCTUnwrap(model.library)
        model.privacyMode = true
        let directory = try model.prepareGIFRecording()
        let input = directory.appendingPathComponent("recording.gif")
        try writeGIF(to: input)
        model.privacyMode = false

        try model.finishGIFRecording(at: input, pasteboard: pasteboard)

        XCTAssertTrue(library.images.isEmpty)
        XCTAssertNil(try library.recentImage())
        XCTAssertNil(pasteboard.string(forType: .fileURL))
        XCTAssertNotNil(pasteboard.data(forType: gifType))
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDiscardingAnUnfinishedGIFRemovesItsWorkingDirectoryWithoutChangingTheVaultOrNamingCounter() throws {
        let (model, defaults, _) = try makeModel()
        let library = try XCTUnwrap(model.library)
        let original = try library.addImage(pixels(gray: 0.5), source: "截图")
        let directory = try model.prepareGIFRecording()
        try Data("incomplete GIF".utf8).write(to: directory.appendingPathComponent(".recording.partial.gif"))

        try model.discardGIFRecording()
        try model.discardGIFRecording()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertEqual(library.images, [original])
        XCTAssertEqual(try library.recentImage(), original)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 1)
    }

    func testMissingPrivateOutputCleansTheOwnedDirectoryAndDoesNotReportSuccessOrChangeTheClipboard() throws {
        let (model, defaults, pasteboard) = try makeModel()
        model.privacyMode = true
        let library = try XCTUnwrap(model.library)
        let directory = try model.prepareGIFRecording()
        let input = directory.appendingPathComponent("recording.gif")
        try Data("incomplete GIF".utf8).write(to: directory.appendingPathComponent(".recording.partial.gif"))
        pasteboard.setString("keep clipboard", forType: .string)
        var completions = 0
        let subscription = model.recordingCompletion.sink { _ in completions += 1 }
        defer { subscription.cancel() }

        XCTAssertThrowsError(try model.finishGIFRecording(at: input, pasteboard: pasteboard))

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(model.gifRecordingDirectory)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep clipboard")
        XCTAssertEqual(completions, 0)
        XCTAssertTrue(library.images.isEmpty)
        XCTAssertEqual(try CaptureFileNaming.nextIndex(for: .recording, defaults: defaults), 1)
    }

    private var gifType: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(UTType.gif.identifier) }

    private func makeModel() throws -> (AppModel, UserDefaults, NSPasteboard) {
        let name = "Clipato.GIFRecordingIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        try CaptureFileNaming.save(screenshot: "Capture-{index}", recording: "GIF-{index}", defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults), defaults: defaults)
        XCTAssertNil(model.errorMessage)
        let library = try XCTUnwrap(model.library)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        addTeardownBlock { @MainActor in
            try model.discardGIFRecording()
            await library.cancelStorageWorkAndWait()
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        return (model, defaults, pasteboard)
    }

    private func writeGIF(to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for gray in [CGFloat(0), 1] {
            CGImageDestinationAddImage(destination, try pixels(gray: gray), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func pixels(gray: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try XCTUnwrap(context.makeImage())
    }
}
