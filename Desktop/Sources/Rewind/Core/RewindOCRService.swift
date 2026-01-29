import Foundation
import Vision
import AppKit

/// Apple Vision-based OCR service for extracting text from screenshots
actor RewindOCRService {
    static let shared = RewindOCRService()

    private init() {}

    // MARK: - Text Extraction

    /// Extract text from JPEG image data using Apple Vision
    func extractText(from imageData: Data) async throws -> String {
        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RewindError.invalidImage
        }

        return try await extractText(from: cgImage)
    }

    /// Extract text from a CGImage
    func extractText(from cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: RewindError.ocrFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let extractedText = observations
                    .compactMap { observation in
                        observation.topCandidates(1).first?.string
                    }
                    .joined(separator: "\n")

                continuation.resume(returning: extractedText)
            }

            // Configure for accuracy over speed
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: RewindError.ocrFailed(error.localizedDescription))
            }
        }
    }

    /// Extract text from an image file at a URL
    func extractText(from url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        return try await extractText(from: data)
    }

    // MARK: - Batch Processing

    /// Process multiple images and return results
    func extractTextBatch(from imageDatas: [Data]) async -> [(index: Int, result: Result<String, Error>)] {
        var results: [(index: Int, result: Result<String, Error>)] = []

        for (index, data) in imageDatas.enumerated() {
            do {
                let text = try await extractText(from: data)
                results.append((index, .success(text)))
            } catch {
                results.append((index, .failure(error)))
            }
        }

        return results
    }
}

// MARK: - NSImage Extension

extension NSImage {
    /// Convert NSImage to CGImage
    func cgImage(forProposedRect proposedRect: UnsafeMutablePointer<NSRect>?, context: NSGraphicsContext?, hints: [NSImageRep.HintKey: Any]?) -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: context, hints: hints)
    }
}
