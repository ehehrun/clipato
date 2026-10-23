import CoreMedia
import XCTest
@testable import Clipato

final class RecordingTimelineTests: XCTestCase {
    func testElapsedFreezesAcrossRepeatedPausesAndStopWhilePaused() {
        var timeline = RecordingTimeline(started: time(100))
        timeline.pause(at: time(102))
        XCTAssertEqual(seconds(timeline.elapsed(at: time(110))), 2)
        timeline.pause(at: time(111))
        timeline.resume(at: time(112))
        timeline.resume(at: time(115))
        XCTAssertEqual(seconds(timeline.elapsed(at: time(116))), 6)
        timeline.pause(at: time(117))
        XCTAssertEqual(seconds(timeline.elapsed(at: time(200))), 7)
        XCTAssertNil(timeline.frameTime(at: time(118)))
    }

    func testLateSamplesCannotCrossPauseBoundaryButNewStreamSnapshotCan() throws {
        var timeline = RecordingTimeline(started: time(100))
        XCTAssertEqual(seconds(try XCTUnwrap(timeline.frameTime(at: time(99)))), 0)
        timeline.pause(at: time(102))
        timeline.resume(at: time(112))
        XCTAssertNil(timeline.frameTime(at: time(111)))
        XCTAssertEqual(seconds(try XCTUnwrap(timeline.frameTime(at: time(111), initialSnapshot: true))), 2)
        XCTAssertEqual(seconds(try XCTUnwrap(timeline.frameTime(at: time(113)))), 3)
    }

    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }
    private func seconds(_ time: CMTime) -> Double { CMTimeGetSeconds(time) }
}
