import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import Clipato

final class RecordingRegionTests: XCTestCase {
    func testConfigurationCropsLogicalPointsAndRetainsNativeRetinaPixels() throws {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 100, y: 80, width: 640, height: 360))
        let configuration = try region.configuration(displayID: 7,
            contentRect: CGRect(x: -1728, y: 200, width: 1728, height: 1117),
            pointPixelScale: 2, maxDimension: 1920)
        XCTAssertEqual(configuration.sourceRect, region.rect)
        XCTAssertEqual(configuration.width, 1280)
        XCTAssertEqual(configuration.height, 720)
    }

    func testOutputMaximumDimensionPreservesRegionAspectAndNeverUpscales() throws {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 0, y: 0, width: 800, height: 600))
        for (density, limit, width, height) in [(CGFloat(2), 1000, 1000, 750), (CGFloat(1), 4096, 800, 600)] {
            let configuration = try region.configuration(displayID: 7,
                contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: density, maxDimension: limit)
            XCTAssertEqual(configuration.width, width)
            XCTAssertEqual(configuration.height, height)
            XCTAssertEqual(configuration.sourceRect, region.rect)
        }
        let portrait = RecordingRegion(displayID: 7, rect: CGRect(x: 0, y: 0, width: 300, height: 900))
        let configuration = try portrait.configuration(displayID: 7,
            contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: 2, maxDimension: 1200)
        XCTAssertEqual(configuration.width, 400)
        XCTAssertEqual(configuration.height, 1200)
    }

    func testAppKitFrameUsesSelectedScreenOriginAndFlipsOnlyLocalY() throws {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 100, y: 80, width: 640, height: 360))
        XCTAssertEqual(try region.appKitFrame(screenFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)),
                       CGRect(x: 100, y: 677, width: 640, height: 360))
        XCTAssertEqual(try region.appKitFrame(screenFrame: CGRect(x: -1728, y: -300, width: 1728, height: 1117)),
                       CGRect(x: -1628, y: 377, width: 640, height: 360))
        XCTAssertEqual(try region.appKitFrame(screenFrame: CGRect(x: 400, y: 1117, width: 1728, height: 1117)),
                       CGRect(x: 500, y: 1794, width: 640, height: 360))
    }

    func testEdgesAndFractionalSelectionRemainExactInSourceCoordinates() throws {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 0.5, y: 0.25, width: 1919.5, height: 1079.75))
        let configuration = try region.configuration(displayID: 7,
            contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: 2, maxDimension: 4096)
        XCTAssertEqual(configuration.sourceRect, region.rect)
        XCTAssertEqual(configuration.width, 3839)
        XCTAssertEqual(configuration.height, 2160)
        let full = RecordingRegion(displayID: 7, rect: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(try full.appKitFrame(screenFrame: CGRect(x: -1920, y: 100, width: 1920, height: 1080)),
                       CGRect(x: -1920, y: 100, width: 1920, height: 1080))
    }

    func testInvalidAndOutOfBoundsRegionsFailInsteadOfCapturingDisplay() {
        let invalid: [CGRect] = [
            .zero, CGRect(x: 0, y: 0, width: -1, height: 20), CGRect(x: 0, y: 0, width: 20, height: -1),
            CGRect(x: -1, y: 0, width: 20, height: 20), CGRect(x: 0, y: -1, width: 20, height: 20),
            CGRect(x: 1901, y: 0, width: 20, height: 20), CGRect(x: 0, y: 1061, width: 20, height: 20),
            CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20), CGRect(x: 0, y: CGFloat.infinity, width: 20, height: 20),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 20)
        ]
        for rect in invalid {
            let region = RecordingRegion(displayID: 7, rect: rect)
            XCTAssertThrowsError(try region.configuration(displayID: 7,
                contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), pointPixelScale: 2, maxDimension: 1920), "\(rect)")
        }
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 10, y: 20, width: 100, height: 100))
        XCTAssertThrowsError(try region.validate(displayID: 8, displaySize: CGSize(width: 1920, height: 1080)))
        XCTAssertThrowsError(try region.validate(displayID: 7, displaySize: .zero))
        XCTAssertThrowsError(try region.appKitFrame(screenFrame: CGRect(x: CGFloat.infinity, y: 0, width: 1920, height: 1080)))
    }

    func testInvalidScaleAndMaximumDimensionAreExplicitFailures() {
        let region = RecordingRegion(displayID: 7, rect: CGRect(x: 10, y: 20, width: 100, height: 100))
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        for scale in [CGFloat.zero, -1, .nan, .infinity] {
            XCTAssertThrowsError(try region.configuration(displayID: 7, contentRect: bounds, pointPixelScale: scale, maxDimension: 1920))
        }
        for maximum in [0, -1] {
            XCTAssertThrowsError(try region.configuration(displayID: 7, contentRect: bounds, pointPixelScale: 2, maxDimension: maximum))
        }
    }
}
