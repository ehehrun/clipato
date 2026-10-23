import XCTest
@testable import Clipato

@MainActor
final class RecordingModeTests: XCTestCase {
    func testSwitchingModeUsesThatModesDefaultFrameRate() throws {
        XCTAssertEqual(try frameRate(.keyframes), 2)
        XCTAssertEqual(try frameRate(.video), 30)
    }

    func testExplicitFrameRateIsNeverReplacedWhenSwitchingMode() throws {
        XCTAssertEqual(try frameRate(.keyframes, fps: 4), 4)
        XCTAssertEqual(try frameRate(.video, fps: 60), 60)
        XCTAssertThrowsError(try frameRate(.video, fps: 4))
        XCTAssertThrowsError(try frameRate(.keyframes, fps: 60))
    }

    func testExplicitKeyframeThresholdRejectsFullVideo() throws {
        XCTAssertEqual(try frameRate(.keyframes, threshold: 0), 2)
        XCTAssertThrowsError(try frameRate(.video, threshold: 0))
        XCTAssertThrowsError(try frameRate(.video, threshold: 0.025))
    }

    func testChosenModeEnforcesItsOutputDimensionLimits() throws {
        XCTAssertEqual(try frameRate(.keyframes, maxDimension: 1), 2)
        XCTAssertEqual(try frameRate(.keyframes, maxDimension: 16_384), 2)
        XCTAssertEqual(try frameRate(.video, maxDimension: 2), 30)
        XCTAssertEqual(try frameRate(.video, maxDimension: 4_096), 30)
        XCTAssertThrowsError(try frameRate(.video, maxDimension: 1))
        XCTAssertThrowsError(try frameRate(.video, maxDimension: 4_097))
        XCTAssertThrowsError(try frameRate(.keyframes, maxDimension: 16_385))
    }

    private func frameRate(_ mode: RecordingMode, fps: Int? = nil, threshold: Double? = nil, maxDimension: Int = 1_920) throws -> Int {
        try ClipatoCLI.recordingFrameRate(mode: mode, fps: fps, threshold: threshold, maxDimension: maxDimension)
    }
}
