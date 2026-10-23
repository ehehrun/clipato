import AppKit
import ClipatoCore
import XCTest
@testable import Clipato

@MainActor
final class LongScreenshotWorkflowTests: XCTestCase {
    func testSingleSelectedImageCanEnterWorkbenchAndSaveToVault() throws {
        let name = "Clipato.LongScreenshotWorkflow.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try FileManager.default.removeItem(at: root)
        }
        let model = AppModel(root: root, shortcuts: ShortcutManager(defaults: defaults))
        let library = try XCTUnwrap(model.library)
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 12, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let original = try library.addImage(XCTUnwrap(context.makeImage()), source: "截图")
        model.selected = [original.id]

        model.composeLongScreenshot()

        let work = try XCTUnwrap(model.longScreenshot)
        XCTAssertEqual(work.images.count, 1)
        let output = try LongScreenshot.render(images: work.images, joins: [])
        try model.saveLongScreenshot(output, tag: .orange)
        XCTAssertEqual(library.images.count, 2)
        let saved = try XCTUnwrap(library.images.first)
        XCTAssertEqual(saved.width, 3)
        XCTAssertEqual(saved.height, 2)
        XCTAssertEqual(saved.tag, .orange)
        XCTAssertEqual(model.selected, [saved.id])
        XCTAssertTrue(model.longScreenshotSaved)
        model.closeLongScreenshot()
        XCTAssertNil(model.longScreenshot)
        XCTAssertNotNil(library.images.first { $0.id == original.id })
    }
}
