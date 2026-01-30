import Foundation
import Vision
import AppKit

/// Represents a text block with its bounding box (in normalized coordinates 0-1)
struct OCRTextBlock: Codable, Equatable {
    let text: String
    /// Bounding box in normalized coordinates (0-1), origin at bottom-left (Vision coordinate system)
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double

    /// Convert to screen coordinates for a given image size
    func screenRect(for imageSize: CGSize) -> CGRect {
        // Vision uses bottom-left origin, convert to top-left origin for display
        let screenX = x * imageSize.width
        let screenY = (1.0 - y - height) * imageSize.height // Flip Y
        let screenWidth = width * imageSize.width
        let screenHeight = height * imageSize.height
        return CGRect(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }
}

/// Complete OCR result with all text blocks
struct OCRResult: Codable, Equatable {
    let fullText: String
    let blocks: [OCRTextBlock]
    let processedAt: Date

    /// Get all blocks that contain the search query (case-insensitive)
    func blocksContaining(_ query: String) -> [OCRTextBlock] {
        let lowercasedQuery = query.lowercased()
        return blocks.filter { $0.text.lowercased().contains(lowercasedQuery) }
    }

    /// Get context snippet around a search match
    func contextSnippet(for query: String, maxLength: Int = 150) -> String? {
        let lowercasedQuery = query.lowercased()
        let lowercasedText = fullText.lowercased()

        guard let range = lowercasedText.range(of: lowercasedQuery) else {
            return nil
        }

        let matchStart = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
        let contextStart = max(0, matchStart - 50)
        let contextEnd = min(fullText.count, matchStart + query.count + 100)

        let startIndex = fullText.index(fullText.startIndex, offsetBy: contextStart)
        let endIndex = fullText.index(fullText.startIndex, offsetBy: contextEnd)

        var snippet = String(fullText[startIndex..<endIndex])

        // Clean up and add ellipsis
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if contextStart > 0 { snippet = "..." + snippet }
        if contextEnd < fullText.count { snippet = snippet + "..." }

        return snippet
    }
}

/// Apple Vision-based OCR service for extracting text from screenshots
actor RewindOCRService {
    static let shared = RewindOCRService()

    private init() {}

    // MARK: - Text Extraction with Bounding Boxes

    /// Extract text with bounding boxes from JPEG image data using Apple Vision
    func extractTextWithBounds(from imageData: Data) async throws -> OCRResult {
        guard let nsImage = NSImage(data: imageData) else {
            throw RewindError.invalidImage
        }

        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw RewindError.invalidImage
        }

        return try await extractTextWithBounds(from: cgImage)
    }

    /// Extract text with bounding boxes from a CGImage
    func extractTextWithBounds(from cgImage: CGImage) async throws -> OCRResult {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: RewindError.ocrFailed(error.localizedDescription))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: OCRResult(fullText: "", blocks: [], processedAt: Date()))
                    return
                }

                var blocks: [OCRTextBlock] = []
                var fullTextLines: [String] = []

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }

                    let boundingBox = observation.boundingBox
                    let block = OCRTextBlock(
                        text: candidate.string,
                        x: boundingBox.origin.x,
                        y: boundingBox.origin.y,
                        width: boundingBox.width,
                        height: boundingBox.height,
                        confidence: Double(candidate.confidence)
                    )
                    blocks.append(block)
                    fullTextLines.append(candidate.string)
                }

                let result = OCRResult(
                    fullText: fullTextLines.joined(separator: "\n"),
                    blocks: blocks,
                    processedAt: Date()
                )
                continuation.resume(returning: result)
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

    // MARK: - Legacy Text-Only Extraction (for compatibility)

    /// Extract text from JPEG image data using Apple Vision
    func extractText(from imageData: Data) async throws -> String {
        let result = try await extractTextWithBounds(from: imageData)
        return result.fullText
    }

    /// Extract text from a CGImage
    func extractText(from cgImage: CGImage) async throws -> String {
        let result = try await extractTextWithBounds(from: cgImage)
        return result.fullText
    }

    /// Extract text from an image file at a URL
    func extractText(from url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        return try await extractText(from: data)
    }

    // MARK: - Batch Processing

    /// Process multiple images and return results with bounding boxes
    func extractTextBatchWithBounds(from imageDatas: [Data]) async -> [(index: Int, result: Result<OCRResult, Error>)] {
        var results: [(index: Int, result: Result<OCRResult, Error>)] = []

        for (index, data) in imageDatas.enumerated() {
            do {
                let ocrResult = try await extractTextWithBounds(from: data)
                results.append((index, .success(ocrResult)))
            } catch {
                results.append((index, .failure(error)))
            }
        }

        return results
    }
}
