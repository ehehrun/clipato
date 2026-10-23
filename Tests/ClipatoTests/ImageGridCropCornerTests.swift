import CoreGraphics
import XCTest
@testable import Clipato

final class ImageGridCropCornerTests: XCTestCase {
    func testCornerPointsUseTopLeftImageCoordinates() {
        let rect = CGRect(x: 40, y: 30, width: 80, height: 80)
        XCTAssertEqual(ImageGridCropCorner.topLeft.point(in: rect), CGPoint(x: 40, y: 30))
        XCTAssertEqual(ImageGridCropCorner.topRight.point(in: rect), CGPoint(x: 120, y: 30))
        XCTAssertEqual(ImageGridCropCorner.bottomLeft.point(in: rect), CGPoint(x: 40, y: 110))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.point(in: rect), CGPoint(x: 120, y: 110))
    }

    func testEachCornerKeepsItsOppositeCornerFixedWhileGrowing() {
        let rect = CGRect(x: 100, y: 100, width: 80, height: 80)
        let bounds = CGSize(width: 400, height: 400)
        XCTAssertEqual(ImageGridCropCorner.topLeft.resized(rect, translation: CGSize(width: -20, height: -20), within: bounds),
                       CGRect(x: 80, y: 80, width: 100, height: 100))
        XCTAssertEqual(ImageGridCropCorner.topRight.resized(rect, translation: CGSize(width: 30, height: -30), within: bounds),
                       CGRect(x: 100, y: 70, width: 110, height: 110))
        XCTAssertEqual(ImageGridCropCorner.bottomLeft.resized(rect, translation: CGSize(width: -10, height: 10), within: bounds),
                       CGRect(x: 90, y: 100, width: 90, height: 90))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(rect, translation: CGSize(width: 20, height: 20), within: bounds),
                       CGRect(x: 100, y: 100, width: 100, height: 100))
    }

    func testHorizontalVerticalAndUnequalDiagonalDragsProduceIntegerSquares() {
        let rect = CGRect(x: 100, y: 100, width: 80, height: 80)
        let bounds = CGSize(width: 400, height: 400)
        XCTAssertEqual(ImageGridCropCorner.topRight.resized(rect, translation: CGSize(width: 30, height: 0), within: bounds),
                       CGRect(x: 100, y: 85, width: 95, height: 95))
        XCTAssertEqual(ImageGridCropCorner.bottomLeft.resized(rect, translation: CGSize(width: -30, height: 0), within: bounds),
                       CGRect(x: 85, y: 100, width: 95, height: 95))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(rect, translation: CGSize(width: 0, height: 21), within: bounds),
                       CGRect(x: 100, y: 100, width: 91, height: 91))
        XCTAssertEqual(ImageGridCropCorner.topLeft.resized(rect, translation: CGSize(width: -12, height: -20), within: bounds),
                       CGRect(x: 84, y: 84, width: 96, height: 96))
        XCTAssertEqual(ImageGridCropCorner.topRight.resized(rect, translation: CGSize(width: -1, height: 0), within: bounds),
                       CGRect(x: 100, y: 101, width: 79, height: 79))
    }

    func testGrowingPastImageEdgesStopsAtTheNearestBoundary() {
        let rect = CGRect(x: 40, y: 30, width: 80, height: 80)
        let bounds = CGSize(width: 200, height: 180)
        XCTAssertEqual(ImageGridCropCorner.topLeft.resized(rect, translation: CGSize(width: -500, height: -500), within: bounds),
                       CGRect(x: 10, y: 0, width: 110, height: 110))
        XCTAssertEqual(ImageGridCropCorner.topRight.resized(rect, translation: CGSize(width: 500, height: -500), within: bounds),
                       CGRect(x: 40, y: 0, width: 110, height: 110))
        XCTAssertEqual(ImageGridCropCorner.bottomLeft.resized(rect, translation: CGSize(width: -500, height: 500), within: bounds),
                       CGRect(x: 0, y: 30, width: 120, height: 120))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(rect, translation: CGSize(width: 500, height: 500), within: bounds),
                       CGRect(x: 40, y: 30, width: 150, height: 150))
    }

    func testDraggingAcrossTheAnchorStopsAtOnePixelWithoutFlipping() {
        let rect = CGRect(x: 40, y: 30, width: 80, height: 80)
        let bounds = CGSize(width: 200, height: 180)
        XCTAssertEqual(ImageGridCropCorner.topLeft.resized(rect, translation: CGSize(width: 500, height: 500), within: bounds),
                       CGRect(x: 119, y: 109, width: 1, height: 1))
        XCTAssertEqual(ImageGridCropCorner.topRight.resized(rect, translation: CGSize(width: -500, height: 500), within: bounds),
                       CGRect(x: 40, y: 109, width: 1, height: 1))
        XCTAssertEqual(ImageGridCropCorner.bottomLeft.resized(rect, translation: CGSize(width: 500, height: -500), within: bounds),
                       CGRect(x: 119, y: 30, width: 1, height: 1))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(rect, translation: CGSize(width: -500, height: -500), within: bounds),
                       CGRect(x: 40, y: 30, width: 1, height: 1))
    }

    func testCumulativeDragUsesTheInitialRectWithoutAJumpOrBoundaryHysteresis() {
        let initial = CGRect(x: 40, y: 30, width: 80, height: 80)
        let bounds = CGSize(width: 200, height: 180)
        for corner in ImageGridCropCorner.allCases {
            XCTAssertEqual(corner.resized(initial, translation: .zero, within: bounds), initial)
        }
        for translation in [CGSize(width: 5.1, height: 6.1), CGSize(width: 5.2, height: 6.2), CGSize(width: 4, height: 8)] {
            XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(initial, translation: translation, within: bounds),
                           CGRect(x: 40, y: 30, width: 86, height: 86))
        }
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(initial, translation: CGSize(width: 500, height: 500), within: bounds),
                       CGRect(x: 40, y: 30, width: 150, height: 150))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(initial, translation: CGSize(width: 10, height: 10), within: bounds),
                       CGRect(x: 40, y: 30, width: 90, height: 90))
        XCTAssertEqual(ImageGridCropCorner.bottomRight.resized(initial, translation: .zero, within: bounds), initial)
    }

    func testTinyCropHitChoosesTheNearestCornerWithStableTies() {
        let rect = CGRect(x: 10, y: 20, width: 2, height: 2)
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 11.8, y: 21.7), in: rect, radius: 6), .bottomRight)
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 11.7, y: 20.1), in: rect, radius: 6), .topRight)
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 10.1, y: 21.9), in: rect, radius: 6), .bottomLeft)
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 11, y: 21), in: rect, radius: 6), .topLeft)
        XCTAssertNil(ImageGridCropCorner.hit(at: CGPoint(x: 30, y: 40), in: rect, radius: 6))
    }

    func testHitHonorsTheRadiusIncludingItsExactBoundary() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 100)
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 7, y: 16), in: rect, radius: 5), .topLeft)
        XCTAssertNil(ImageGridCropCorner.hit(at: CGPoint(x: 6.99, y: 16), in: rect, radius: 5))
        XCTAssertEqual(ImageGridCropCorner.hit(at: CGPoint(x: 110, y: 120), in: rect, radius: 0), .bottomRight)
        XCTAssertNil(ImageGridCropCorner.hit(at: CGPoint(x: 10, y: 20), in: rect, radius: -1))
    }
}
