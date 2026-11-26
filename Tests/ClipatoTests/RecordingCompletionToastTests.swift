import CoreGraphics
import XCTest
@testable import Clipato

final class RecordingCompletionToastTests: XCTestCase {
    func testToastIsCenteredBelowTheTopOfTheRecordingScreensVisibleFrame() {
        let screen = CGRect(x: 0, y: 80, width: 1728, height: 1000)
        let frame = RecordingCompletionToast.frame(for: CGSize(width: 460, height: 48), within: screen)
        XCTAssertEqual(frame, CGRect(x: 634, y: 1016, width: 460, height: 48))
        XCTAssertTrue(screen.contains(frame))
    }

    func testExternalDisplaysKeepTheirOwnGlobalCoordinates() {
        let displays = [
            CGRect(x: -1920, y: -180, width: 1920, height: 1080),
            CGRect(x: 400, y: 1117, width: 1728, height: 1117),
        ]
        for display in displays {
            let frame = RecordingCompletionToast.frame(for: CGSize(width: 460, height: 74), within: display)
            XCTAssertEqual(frame.midX, display.midX)
            XCTAssertEqual(frame.maxY, display.maxY - 16)
            XCTAssertEqual(frame.size, CGSize(width: 460, height: 74))
            XCTAssertTrue(display.contains(frame))
        }
    }

    func testOversizedToastStaysInsideTheAvailableScreenWithoutInvalidOrigins() {
        let screen = CGRect(x: -300, y: 200, width: 300, height: 120)
        let frame = RecordingCompletionToast.frame(for: CGSize(width: 460, height: 180), within: screen)
        XCTAssertEqual(frame, screen)
        let tall = RecordingCompletionToast.frame(for: CGSize(width: 180, height: 110), within: screen)
        XCTAssertEqual(tall, CGRect(x: -240, y: 200, width: 180, height: 110))
    }
}
