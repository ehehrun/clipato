import XCTest
@testable import ClipatoCore

final class FrameDifferenceTests: XCTestCase {
    func testIdenticalRGBIgnoresAlpha() {
        let previous: [UInt8] = [30, 50, 70, 0, 100, 110, 120, 0]
        let current: [UInt8] = [30, 50, 70, 255, 100, 110, 120, 255]
        XCTAssertEqual(FrameDifference.score(previous: previous, current: current, width: 2, height: 1), 0)
    }

    func testUniformDifferenceIsNormalized() {
        let previous = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let current = [UInt8](repeating: 51, count: previous.count)
        XCTAssertEqual(FrameDifference.score(previous: previous, current: current, width: 16, height: 16), 0.2, accuracy: 0.000001)
    }

    func testSmallLocalEditIsNotDilutedByDesktopArea() {
        let width = 256
        let height = 144
        let previous = [UInt8](repeating: 0, count: width * height * 4)
        var current = previous
        for x in 0..<16 {
            current[x * 4] = 255
            current[x * 4 + 1] = 255
            current[x * 4 + 2] = 255
        }
        // A sixteen-pixel text stroke covers less than 0.05% of this thumbnail.
        XCTAssertEqual(FrameDifference.score(previous: previous, current: current, width: width, height: height), 1.0 / 16, accuracy: 0.000001)
    }

    func testPartialEdgeTileUsesItsActualArea() {
        let width = 17
        let previous = [UInt8](repeating: 0, count: width * 4)
        var current = previous
        current[16 * 4] = 255
        current[16 * 4 + 1] = 255
        current[16 * 4 + 2] = 255
        XCTAssertEqual(FrameDifference.score(previous: previous, current: current, width: width, height: 1), 1)
    }

    func testAccumulatedChangesCrossThresholdAgainstLastSavedFrame() {
        let previous = [UInt8](repeating: 100, count: 16 * 16 * 4)
        let first = [UInt8](repeating: 104, count: previous.count)
        let later = [UInt8](repeating: 108, count: previous.count)
        let threshold = 0.025
        XCTAssertLessThan(FrameDifference.score(previous: previous, current: first, width: 16, height: 16), threshold)
        XCTAssertGreaterThan(FrameDifference.score(previous: previous, current: later, width: 16, height: 16), threshold)
        XCTAssertEqual(
            FrameDifference.score(previous: previous, current: later, width: 16, height: 16),
            FrameDifference.score(previous: later, current: previous, width: 16, height: 16)
        )
    }
}
