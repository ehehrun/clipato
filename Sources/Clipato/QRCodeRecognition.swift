import CoreGraphics
import Foundation
import Vision

enum QRCodeRecognition {
    static func contents(in image: CGImage) async throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            guard let observations = request.results else { throw RecognitionError.missingResults }
            return try observations.map { observation in
                guard let text = observation.payloadStringValue, !text.isEmpty else { throw RecognitionError.noText }
                return text
            }
        } onCancel: {
            request.cancel()
        }
    }

    private enum RecognitionError: LocalizedError {
        case missingResults
        case noText

        var errorDescription: String? {
            switch self {
            case .missingResults: return L("二维码识别未返回结果。")
            case .noText: return L("二维码中没有可复制的文本。")
            }
        }
    }
}
