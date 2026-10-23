import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Clipato

@MainActor
final class ImageOrientationTests: XCTestCase {
    func testCameraJPEGUsesEXIFOrientationWithoutChangingOriginalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("camera.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: url)
        let store = try LibraryStore(root: root.appendingPathComponent("Vault"))
        try store.importImages([url])
        let item = try XCTUnwrap(store.images.first)
        let image = try store.loadImage(item)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 60)
        XCTAssertEqual(item.width, 40)
        XCTAssertEqual(item.height, 60)
        XCTAssertEqual(try Data(contentsOf: store.imageURL(item)), bytes)
    }

    func testIndependentStoreWritersDoNotOverwriteEarlierImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let first = try LibraryStore(root: root)
        let second = try LibraryStore(root: root)
        let firstItem = try first.addImage(image, source: "first")
        let secondItem = try second.addImage(image, source: "second")
        let thirdItem = try first.addImage(image, source: "third")
        let reloaded = try LibraryStore(root: root)
        XCTAssertEqual(Set(reloaded.images.map(\.id)), Set([firstItem.id, secondItem.id, thirdItem.id]))
        for item in reloaded.images { XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.imageURL(item).path)) }
    }
}
