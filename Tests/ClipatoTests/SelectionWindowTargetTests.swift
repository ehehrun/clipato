import CoreGraphics
import Foundation
import XCTest
@testable import Clipato

final class SelectionWindowTargetTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1200, height: 800)

    func testKeepsFrontToBackOrderForCompleteUnobscuredWindows() throws {
        let first = CGRect(x: 50, y: 80, width: 240, height: 180)
        let second = CGRect(x: 500, y: 300, width: 320, height: 240)
        let result = try SelectionWindowTarget.targets(in: [window(17, first), window(6, second)],
                                                       displayFrame: display, shareableWindowIDs: [6, 17])
        XCTAssertEqual(result, [.init(windowID: 17, frame: first), .init(windowID: 6, frame: second)])
    }

    func testConvertsNegativeAndOffsetDisplayOriginsWithoutScalingOrFlipping() throws {
        for screen in [CGRect(x: -1600, y: -900, width: 1600, height: 900),
                       CGRect(x: 1440, y: 900, width: 1280, height: 720)] {
            let local = CGRect(x: 110.25, y: 125.5, width: 310, height: 200)
            let global = local.offsetBy(dx: screen.minX, dy: screen.minY)
            let result = try SelectionWindowTarget.targets(in: [window(4, global)],
                                                           displayFrame: screen, shareableWindowIDs: [4])
            XCTAssertEqual(result, [.init(windowID: 4, frame: local)])
        }
    }

    func testDoesNotTurnPartiallyOffscreenWindowsIntoClippedTargets() throws {
        for frame in [CGRect(x: -1, y: 40, width: 240, height: 180),
                      CGRect(x: 1000, y: 40, width: 240, height: 180),
                      CGRect(x: 40, y: -1, width: 240, height: 180),
                      CGRect(x: 40, y: 700, width: 240, height: 180)] {
            let result = try SelectionWindowTarget.targets(in: [window(4, frame)],
                                                           displayFrame: display, shareableWindowIDs: [4])
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testPartiallyObscuredBackgroundWindowIsNotACompleteTarget() throws {
        let front = CGRect(x: 100, y: 100, width: 200, height: 200)
        let back = CGRect(x: 50, y: 50, width: 500, height: 400)
        let result = try SelectionWindowTarget.targets(in: [window(1, front), window(2, back)],
                                                       displayFrame: display, shareableWindowIDs: [1, 2])
        XCTAssertEqual(result, [.init(windowID: 1, frame: front)])
    }

    func testNonSelectableForegroundWindowsStillBlockWindowsBehindThem() throws {
        let target = CGRect(x: 100, y: 100, width: 300, height: 200)
        let blockers = [window(1, target, layer: 101),
                        window(1, target, layer: 20),
                        window(1, target),
                        window(1, CGRect(x: -100, y: 120, width: 300, height: 100))]
        for blocker in blockers {
            let result = try SelectionWindowTarget.targets(in: [blocker, window(2, target)],
                                                           displayFrame: display, shareableWindowIDs: [2])
            XCTAssertTrue(result.isEmpty)
        }
    }

    func testTransparentAndInvalidGeometryDoNotBlockWindowsBehindThem() throws {
        let target = CGRect(x: 100, y: 100, width: 300, height: 200)
        let ignored = [window(1, target, alpha: 0),
                       window(1, CGRect(x: 200, y: 100, width: 0, height: 200)),
                       window(1, CGRect(x: 200, y: 100, width: -100, height: 200)),
                       window(1, CGRect(x: CGFloat.nan, y: 100, width: 100, height: 200)),
                       window(1, CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 200))]
        for info in ignored {
            let result = try SelectionWindowTarget.targets(in: [info, window(2, target)],
                                                           displayFrame: display, shareableWindowIDs: [1, 2])
            XCTAssertEqual(result, [.init(windowID: 2, frame: target)])
        }
    }

    func testAcceptsApplicationWindowLevelsAndExcludesDesktopDockAndMenus() throws {
        let levels = [0, 3, 8, 19, 20, 24, 25, 101, 1000, -1]
        let info = levels.enumerated().map { index, layer in
            window(CGWindowID(index + 1), CGRect(x: index * 100, y: 50, width: 80, height: 80), layer: layer)
        }
        let result = try SelectionWindowTarget.targets(in: info, displayFrame: display,
                                                       shareableWindowIDs: Set(1...10))
        XCTAssertEqual(result.map(\.windowID), [1, 2, 3, 4])
    }

    func testTouchingEdgesAndCornersDoNotCountAsOcclusion() throws {
        let frames = [CGRect(x: 0, y: 50, width: 200, height: 200),
                      CGRect(x: 200, y: 50, width: 200, height: 200),
                      CGRect(x: 200, y: 250, width: 200, height: 100),
                      CGRect(x: 1100, y: 700, width: 100, height: 100)]
        let info = frames.enumerated().map { window(CGWindowID($0.offset + 1), $0.element) }
        let result = try SelectionWindowTarget.targets(in: info, displayFrame: display, shareableWindowIDs: [1, 2, 3, 4])
        XCTAssertEqual(result.map(\.frame), frames)
    }

    func testTranslucentForegroundWindowStillBlocksTheFrozenComposite() throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let result = try SelectionWindowTarget.targets(in: [window(1, frame, alpha: 0.2), window(2, frame)],
                                                       displayFrame: display, shareableWindowIDs: [2])
        XCTAssertTrue(result.isEmpty)
    }

    func testOffDisplayWindowsDoNotBlockTargetsAndUnsharedIDsAreNotInvented() throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let info = [window(1, CGRect(x: 1300, y: 100, width: 300, height: 200)), window(2, frame)]
        let result = try SelectionWindowTarget.targets(in: info, displayFrame: display, shareableWindowIDs: [2])
        XCTAssertEqual(result, [.init(windowID: 2, frame: frame)])
        XCTAssertTrue(try SelectionWindowTarget.targets(in: info, displayFrame: display, shareableWindowIDs: [99]).isEmpty)
    }

    func testMissingOrWrongTypedMandatoryFieldsFailClearly() throws {
        let valid = window(4, CGRect(x: 100, y: 100, width: 300, height: 200))
        for key in [kCGWindowNumber, kCGWindowLayer, kCGWindowAlpha, kCGWindowBounds] {
            for value in [nil, "invalid" as Any?] {
                var invalid = valid
                invalid[key as String] = value
                XCTAssertThrowsError(try SelectionWindowTarget.targets(in: [invalid], displayFrame: display,
                                                                       shareableWindowIDs: [4])) { error in
                    XCTAssertEqual((error as? CocoaError)?.code, .propertyListReadCorrupt)
                }
            }
        }
        var invalidBounds = valid
        invalidBounds[kCGWindowBounds as String] = ["Width": 300]
        XCTAssertThrowsError(try SelectionWindowTarget.targets(in: [invalidBounds], displayFrame: display,
                                                               shareableWindowIDs: [4]))
    }

    private func window(_ windowID: CGWindowID, _ frame: CGRect, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: windowID),
         kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowLayer as String: NSNumber(value: layer),
         kCGWindowAlpha as String: NSNumber(value: alpha)]
    }
}
