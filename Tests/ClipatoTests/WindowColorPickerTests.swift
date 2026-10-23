import AppKit
import XCTest
@testable import Clipato

@MainActor
final class WindowColorPickerTests: XCTestCase {
    func testPanelUsesSourceDisplayCoordinatesOnEitherSideAndAbovePrimaryDisplay() {
        let size = CGSize(width: 300, height: 420)
        for screen in [CGRect(x: -1920, y: 25, width: 1920, height: 1030),
                       CGRect(x: 1920, y: 25, width: 1920, height: 1030),
                       CGRect(x: 0, y: 1105, width: 1920, height: 1030)] {
            let anchor = CGRect(x: screen.minX + 500, y: screen.minY + 600, width: 36, height: 24)
            let origin = WindowColorWell.panelOrigin(size: size, anchor: anchor, within: screen)
            XCTAssertEqual(origin.x, anchor.maxX + 12)
            XCTAssertEqual(origin.y + size.height, anchor.maxY)
            XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
        }
    }

    func testPanelOpensLeftOfRightEdgeAndStaysAboveDock() {
        let screen = CGRect(x: -1600, y: 80, width: 1600, height: 900)
        let anchor = CGRect(x: -80, y: 100, width: 36, height: 24)
        let size = CGSize(width: 300, height: 420)
        let origin = WindowColorWell.panelOrigin(size: size, anchor: anchor, within: screen)
        XCTAssertEqual(origin.x + size.width, anchor.minX - 12)
        XCTAssertEqual(origin.y, screen.minY)
        XCTAssertTrue(screen.contains(CGRect(origin: origin, size: size)))
    }

    func testOversizedPanelKeepsTitlebarOnSourceScreen() {
        let screen = CGRect(x: 1920, y: 80, width: 800, height: 600)
        let size = CGSize(width: 900, height: 700)
        let origin = WindowColorWell.panelOrigin(size: size, anchor: CGRect(x: 2500, y: 100, width: 36, height: 24), within: screen)
        XCTAssertEqual(origin.x, screen.minX)
        XCTAssertEqual(origin.y + size.height, screen.maxY)
    }

    func testNativeWellForwardsChosenColorWithoutOpeningPanel() {
        _ = NSApplication.shared
        var received: NSColor?
        let well = WindowColorWell(title: "背景") { received = $0 }
        XCTAssertEqual(well.colorWellStyle, .default)
        XCTAssertFalse(well.supportsAlpha)
        XCTAssertNil(well.window)
        well.color = NSColor(srgbRed: 0.4, green: 0.7, blue: 0.2, alpha: 1)
        well.sendAction(well.action, to: well.target)
        XCTAssertEqual(received, well.color)
        XCTAssertFalse(well.isActive)
    }
}
