import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import XCTest
@testable import Clipato

final class QRCodeRecognitionTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    func testURLPayloadIsReturnedWithoutOpeningOrChangingIt() async throws {
        let payload = "https://clipato.kodify.vip/?source=screenshot&value=hello%20world#qr"
        let actual = try await QRCodeRecognition.contents(in: qrCode(payload))
        XCTAssertEqual(actual, [payload])
    }

    func testUnicodeWhitespaceAndLineBreaksArePreserved() async throws {
        let payload = "  Clipato 二维码\n第二行 🙂\n  "
        let actual = try await QRCodeRecognition.contents(in: qrCode(payload))
        XCTAssertEqual(actual, [payload])
    }

    func testMultipleCodesReturnEveryPayload() async throws {
        let payloads = ["https://clipato.kodify.vip/first", "WIFI:T:WPA;S:Clipato;P:test-password;;"]
        let image = try canvas(with: payloads.map(qrCode))
        let actual = try await QRCodeRecognition.contents(in: image)
        XCTAssertEqual(actual.count, payloads.count)
        XCTAssertEqual(Set(actual), Set(payloads))
    }

    func testSeparateCodesWithTheSameContentAreNotDeduplicated() async throws {
        let payload = "Clipato duplicate payload"
        let code = try qrCode(payload)
        let actual = try await QRCodeRecognition.contents(in: canvas(with: [code, code]))
        XCTAssertEqual(actual, [payload, payload])
    }

    func testBlankImageAndLinearBarcodeHaveNoQRCodeResults() async throws {
        let blank = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let barcode = CIFilter.code128BarcodeGenerator()
        barcode.message = Data("1234567890".utf8)
        let output = try XCTUnwrap(barcode.outputImage).transformed(by: CGAffineTransform(scaleX: 3, y: 4))
        for input in [blank, output] {
            let image = try XCTUnwrap(context.createCGImage(input, from: input.extent))
            let actual = try await QRCodeRecognition.contents(in: image)
            XCTAssertTrue(actual.isEmpty)
        }
    }

    func testCancelledOperationDoesNotReturnRecognizedContent() async throws {
        let image = try qrCode("Clipato cancellation")
        let operation = Task {
            withUnsafeCurrentTask { $0!.cancel() }
            return try await QRCodeRecognition.contents(in: image)
        }
        do {
            _ = try await operation.value
            XCTFail("A cancelled recognition must not publish QR content.")
        } catch is CancellationError {
        }
    }

    private func qrCode(_ payload: String) throws -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let background = CIImage(color: .white).cropped(to: output.extent.insetBy(dx: -32, dy: -32))
        let padded = output.composited(over: background)
        return try XCTUnwrap(context.createCGImage(padded, from: padded.extent))
    }

    private func canvas(with codes: [CGImage]) throws -> CGImage {
        let gap = 80
        let width = codes.reduce(gap) { $0 + $1.width + gap }
        let height = try XCTUnwrap(codes.map(\.height).max()) + gap * 2
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .none
        var x = gap
        for code in codes {
            canvas.draw(code, in: CGRect(x: x, y: gap, width: code.width, height: code.height))
            x += code.width + gap
        }
        return try XCTUnwrap(canvas.makeImage())
    }
}
