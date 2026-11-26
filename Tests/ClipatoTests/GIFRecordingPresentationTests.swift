import XCTest
@testable import Clipato

@MainActor
final class GIFRecordingPresentationTests: XCTestCase {
    func testVideoSelectionKeepsItsTwoModesSeparateFromGIFRecording() {
        XCTAssertEqual(SelectionView.videoRecordingModes, [.keyframes, .video])
        XCTAssertFalse(SelectionView.videoRecordingModes.contains(.gif))
        XCTAssertTrue(RecordingMode.allCases.contains(.gif))
    }

    func testGIFSelectionAndRecorderUseTheSameDefaultAndSupportedFrameRates() throws {
        let settings = GIFRecordingSettings()
        XCTAssertEqual(settings.frameRate, RecordingMode.gif.defaultFrameRate)
        XCTAssertEqual(GIFRecordingSettings.frameRates, RecordingMode.gif.frameRates)
        for rate in RecordingMode.gif.frameRates {
            XCTAssertNoThrow(try GIFRecordingSettings(frameRate: rate).validate())
        }
    }

    func testEveryGIFQualityFitsTheRecorderDimensionRange() throws {
        for quality in GIFRecordingQuality.allCases {
            let settings = GIFRecordingSettings(quality: quality)
            XCTAssertNoThrow(try settings.validate())
            XCTAssertTrue(RecordingMode.gif.maximumDimensionRange.contains(settings.maximumDimension))
        }
    }
}
