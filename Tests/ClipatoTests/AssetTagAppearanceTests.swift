import AppKit
import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class AssetTagAppearanceTests: XCTestCase {
    func testSwatchesRetainTagColorsInLightAndDarkAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for tag in AssetTag.allCases {
                    let swatch = tag.swatch
                    XCTAssertFalse(swatch.isTemplate)
                    XCTAssertTrue(swatch === tag.swatch)
                    let expected = NSColor(tag.color).usingColorSpace(.sRGB)!
                    let context = CGContext(data: nil, width: 12, height: 12,
                        bitsPerComponent: 8, bytesPerRow: 48,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                    swatch.draw(in: CGRect(x: 0, y: 0, width: 12, height: 12))
                    NSGraphicsContext.restoreGraphicsState()
                    let pixel = context.data!.assumingMemoryBound(to: UInt8.self) + 6 * 48 + 6 * 4
                    XCTAssertEqual(Double(pixel[0]), Double(expected.redComponent * 255), accuracy: 1, "\(name) \(tag)")
                    XCTAssertEqual(Double(pixel[1]), Double(expected.greenComponent * 255), accuracy: 1, "\(name) \(tag)")
                    XCTAssertEqual(Double(pixel[2]), Double(expected.blueComponent * 255), accuracy: 1, "\(name) \(tag)")
                    XCTAssertEqual(pixel[3], 255)
                }
            }
        }
    }

    func testNativePickerUsesOriginalSharedSwatchesUnderControlTint() throws {
        let picker = NativeAssetTagPicker()
        picker.contentTintColor = .systemPink
        for tag in AssetTag.allCases {
            picker.assetTag = tag
            let image = try XCTUnwrap(picker.selectedItem?.image)
            XCTAssertTrue(image === tag.swatch)
            XCTAssertFalse(image.isTemplate)
        }
    }

    func testNativePickerCheckmarkTracksProgrammaticAndUserSelections() {
        _ = NSApplication.shared
        let picker = NativeAssetTagPicker()
        XCTAssertEqual(picker.itemArray.filter { $0.state == .on }.map(\.title), [L("无标签")])
        picker.assetTag = .green
        XCTAssertEqual(picker.itemArray.filter { $0.state == .on }.map(\.title), [AssetTag.green.title])
        var changes: [AssetTag?] = []
        picker.onChange = { changes.append($0) }
        picker.selectItem(withTitle: AssetTag.red.title)
        XCTAssertTrue(picker.sendAction(picker.action, to: picker.target))
        XCTAssertEqual(picker.itemArray.filter { $0.state == .on }.map(\.title), [AssetTag.red.title])
        XCTAssertEqual(changes, [.red])
        picker.assetTag = nil
        XCTAssertEqual(picker.itemArray.filter { $0.state == .on }.map(\.title), [L("无标签")])
        XCTAssertEqual(changes, [.red])
    }
}
