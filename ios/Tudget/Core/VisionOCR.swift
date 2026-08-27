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
    /// Tries the recognized lines joined together first, since bank alerts
    /// usually wrap one sentence across lines. If that yields no amount, it
    /// falls back to scanning individual lines, which rescues layouts where
    /// the amount sits alone in its own block.
    static func extractPurchase(
        from image: UIImage, defaultCurrency: String
    ) async throws -> PurchaseTextParser.NotificationPurchase? {
        let lines = try await recognizeText(in: image)
        guard !lines.isEmpty else { return nil }

        let joined = lines.joined(separator: " ")
        if let purchase = PurchaseTextParser.parseNotification(
            joined, defaultCurrency: defaultCurrency
        ) {
            return purchase
        }

        for line in lines {
            if let purchase = PurchaseTextParser.parseNotification(
                line, defaultCurrency: defaultCurrency
            ) {
                // Keep the full text around even when only one line parsed, so
                // the review screen can show everything that was on screen.
                return PurchaseTextParser.NotificationPurchase(
                    merchant: purchase.merchant
                        ?? PurchaseTextParser.extractMerchant(from: joined),
                    amount: purchase.amount,
                    currencyCode: purchase.currencyCode,
                    rawText: joined
                )
            }
        }

        return nil
    }
    #endif
}
