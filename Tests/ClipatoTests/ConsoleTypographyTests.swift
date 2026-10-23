import SwiftUI
import XCTest
@testable import Clipato

@MainActor
final class ConsoleTypographyTests: XCTestCase {
    func testFontMultiplierAndDefaultEnvironmentUnscaled() {
        XCTAssertEqual(EnvironmentValues().consoleFontScale, 1)
        for (size, multiplier) in [(ConsoleFontSize.small, 12.0 / 14), (.normal, 1), (.large, 16.0 / 14), (.extraLarge, 18.0 / 14), (.largest, 20.0 / 14)] {
            XCTAssertEqual(size.scale, multiplier, accuracy: 0.0001)
        }
    }
}
