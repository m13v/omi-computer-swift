import Foundation
import Accelerate

/// Actor-based service for embedding screenshot OCR text using Gemini embeddings
/// and performing disk-based vector search (no in-memory index).
actor OCREmbeddingService {
    static let shared = OCREmbeddingService()

    private let embeddingDimension = 768
    private let minTextLength = 10

    private init() {}

    // MARK: - Single Embedding (for new screenshots in pipeline)

    /// Embed a single screenshot's OCR text and store the result
    func embedScreenshot(id: Int64, ocrText: String) async {
        guard ocrText.count >= minTextLength else { return }

        do {
            let embedding = try await EmbeddingService.shared.embed(text: ocrText)
            let data = await EmbeddingService.shared.floatsToData(embedding)
            try RewindDatabase.shared.updateScreenshotEmbedding(id: id, embedding: data)
        } catch {
            // Non-fatal: embedding failures don't block the pipeline
            logError("OCREmbeddingService: Failed to embed screenshot \(id)", error: error)
        }
    }

    // MARK: - Backfill

    /// Backfill embeddings for existing screenshots that have OCR text but no embedding
    func backfillIfNeeded() async {
        do {
            let status = try RewindDatabase.shared.getOCREmbeddingBackfillStatus()
            if status.completed {
                log("OCREmbeddingService: Backfill already complete, skipping")
                return
            }

            log("OCREmbeddingService: Starting backfill (previously processed: \(status.processedCount))")

            let batchSize = 100
            var totalProcessed = status.processedCount

            while true {
                let items = try RewindDatabase.shared.getScreenshotsMissingEmbeddings(limit: batchSize)
                if items.isEmpty { break }

                let texts = items.map { $0.ocrText }
                let embeddings: [[Float]]
                do {
                    embeddings = try await EmbeddingService.shared.embedBatch(texts: texts)
                } catch {
                    logError("OCREmbeddingService: Batch embed failed, will retry later", error: error)
                    break
                }

                for (i, embedding) in embeddings.enumerated() where i < items.count {
                    let item = items[i]
                    let data = await EmbeddingService.shared.floatsToData(embedding)
                    try RewindDatabase.shared.updateScreenshotEmbedding(id: item.id, embedding: data)
                }

                totalProcessed += items.count

                // Update progress every 1000 items
                if totalProcessed % 1000 < batchSize {
                    try RewindDatabase.shared.updateOCREmbeddingBackfillStatus(completed: false, processedCount: totalProcessed)
                    log("OCREmbeddingService: Backfill progress: \(totalProcessed) items")
                }

                // Rate limiting delay between batches
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            // Mark complete
            try RewindDatabase.shared.updateOCREmbeddingBackfillStatus(completed: true, processedCount: totalProcessed)
            log("OCREmbeddingService: Backfill complete — \(totalProcessed) items embedded")

        } catch {
            logError("OCREmbeddingService: Backfill failed", error: error)
        }
    }

    // MARK: - Disk-Based Semantic Search

    /// Search for screenshots similar to a query using disk-based vector search
    /// Reads embedding BLOBs from SQLite in batches, computes cosine similarity via vDSP
    func searchSimilar(
        query: String,
        startDate: Date,
        endDate: Date,
        appFilter: String? = nil,
        topK: Int = 50
    ) async throws -> [(screenshotId: Int64, similarity: Float)] {
        // Embed the query
        let queryEmbedding = try await EmbeddingService.shared.embed(text: query)

        let batchSize = 5000
        var offset = 0
        var topResults: [(screenshotId: Int64, similarity: Float)] = []

        while true {
            let batch = try RewindDatabase.shared.readEmbeddingBatch(
                startDate: startDate,
                endDate: endDate,
                appFilter: appFilter,
                limit: batchSize,
                offset: offset
            )

            if batch.isEmpty { break }

            for (screenshotId, embeddingData) in batch {
                guard let storedEmbedding = dataToFloats(embeddingData) else { continue }
                let sim = cosineSimilarity(queryEmbedding, storedEmbedding)
                topResults.append((screenshotId: screenshotId, similarity: sim))
            }

            // Compact top results periodically to keep memory bounded
            if topResults.count > topK * 2 {
                topResults.sort { $0.similarity > $1.similarity }
                topResults = Array(topResults.prefix(topK))
            }

            offset += batchSize
        }

        // Final sort and trim
        topResults.sort { $0.similarity > $1.similarity }
        return Array(topResults.prefix(topK))
    }

    // MARK: - Helpers

    /// Cosine similarity using Accelerate vDSP
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        // Vectors are pre-normalized, so dot product = cosine similarity
        return dot
    }

    /// Convert Data (BLOB) back to [Float]
    private func dataToFloats(_ data: Data) -> [Float]? {
        guard data.count == embeddingDimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }
}
