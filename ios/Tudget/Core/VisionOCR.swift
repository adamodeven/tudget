import Foundation
import Vision

#if canImport(UIKit)
import UIKit
#endif

/// Reads text off a screenshot using Apple's Vision framework.
///
/// This replaces the server-side tesseract pass entirely: recognition happens
/// on device, needs no network, no binary to install, and is materially more
/// accurate on the kind of image this app actually gets -- a screenshot of a
/// bank push notification.
enum VisionOCR {

    enum OCRError: Error {
        case invalidImage
        case recognitionFailed(Error)
    }

    /// Recognized lines, top to bottom, as Vision ordered them.
    static func recognizeText(in cgImage: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.recognitionFailed(error))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            // Notification text is ordinary prose and merchant names; language
            // correction helps the prose and rarely hurts the names.
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OCRError.recognitionFailed(error))
            }
        }
    }

    #if canImport(UIKit)
    static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await recognizeText(in: cgImage)
    }

    /// The whole pipeline: screenshot in, purchase out.
    ///
    /// The lines are handed over intact rather than pre-joined: a bank alert's
    /// sentence reads the same either way, but on an app screen the line
    /// breaks are what tell the parser which text is the merchant.
    static func extractPurchase(
        from image: UIImage, defaultCurrency: String
    ) async throws -> PurchaseTextParser.NotificationPurchase? {
        let lines = try await recognizeText(in: image)
        return PurchaseTextParser.parseScreenshot(
            lines: lines, defaultCurrency: defaultCurrency
        )
    }
    #endif
}
