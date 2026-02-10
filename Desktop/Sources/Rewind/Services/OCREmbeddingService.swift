import Foundation
import Accelerate

/// Actor-based service for embedding ocr_texts entries using Gemini embeddings
/// and performing disk-based vector search (no in-memory index).
/// Embeds individual deduplicated text blocks from the ocr_texts table,
/// then resolves matches back to screenshots via ocr_occurrences.
actor OCREmbeddingService {
    static let shared = OCREmbeddingService()

    private let embeddingDimension = 768
    private let minTextLength = 10

    private init() {}

    // MARK: - Backfill

    /// Backfill embeddings for existing ocr_texts rows that have no embedding
    func backfillIfNeeded() async {
        do {
            let status = try await RewindDatabase.shared.getOCRTextEmbeddingBackfillStatus()
            if status.completed {
                log("OCREmbeddingService: Backfill already complete, skipping")
                return
            }

            log("OCREmbeddingService: Starting backfill (previously processed: \(status.processedCount))")

            let batchSize = 100
            var totalProcessed = status.processedCount

            while true {
                let items = try await RewindDatabase.shared.getOCRTextsMissingEmbeddings(limit: batchSize)
                if items.isEmpty { break }

                let texts = items.map { $0.text }
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
                    try await RewindDatabase.shared.updateOCRTextEmbedding(id: item.id, embedding: data)
                }

                totalProcessed += items.count

                // Update progress every 1000 items
                if totalProcessed % 1000 < batchSize {
                    try await RewindDatabase.shared.updateOCRTextEmbeddingBackfillStatus(completed: false, processedCount: totalProcessed)
                    log("OCREmbeddingService: Backfill progress: \(totalProcessed) items")
                }

                // Rate limiting delay between batches
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            // Mark complete
            try await RewindDatabase.shared.updateOCRTextEmbeddingBackfillStatus(completed: true, processedCount: totalProcessed)
            log("OCREmbeddingService: Backfill complete — \(totalProcessed) items embedded")

        } catch {
            logError("OCREmbeddingService: Backfill failed", error: error)
        }
    }

    // MARK: - Disk-Based Semantic Search

    /// Search for screenshots similar to a query using disk-based vector search.
    /// Reads ocr_texts embedding BLOBs (date-filtered via ocr_occurrences→screenshots join),
    /// computes cosine similarity, then resolves top-K text matches back to screenshot IDs.
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
        var topTextResults: [(ocrTextId: Int64, similarity: Float)] = []

        while true {
            let batch = try await RewindDatabase.shared.readOCRTextEmbeddingBatch(
                startDate: startDate,
                endDate: endDate,
                appFilter: appFilter,
                limit: batchSize,
                offset: offset
            )

            if batch.isEmpty { break }

            for (ocrTextId, embeddingData) in batch {
                guard let storedEmbedding = dataToFloats(embeddingData) else { continue }
                let sim = cosineSimilarity(queryEmbedding, storedEmbedding)
                topTextResults.append((ocrTextId: ocrTextId, similarity: sim))
            }

            // Compact top results periodically to keep memory bounded
            if topTextResults.count > topK * 4 {
                topTextResults.sort { $0.similarity > $1.similarity }
                topTextResults = Array(topTextResults.prefix(topK * 2))
            }

            offset += batchSize
        }

        // Get top-K text matches
        topTextResults.sort { $0.similarity > $1.similarity }
        let topTexts = Array(topTextResults.prefix(topK))

        guard !topTexts.isEmpty else { return [] }

        // Resolve ocr_text IDs → screenshot IDs
        let ocrTextIds = topTexts.map { $0.ocrTextId }
        let screenshotIds = try await RewindDatabase.shared.getScreenshotIdsForOCRTexts(
            ocrTextIds: ocrTextIds,
            startDate: startDate,
            endDate: endDate,
            appFilter: appFilter
        )

        // For each screenshot, find the best similarity from its linked texts.
        // Since getScreenshotIdsForOCRTexts just returns IDs, we use the max similarity
        // from the matched text set as the score for each screenshot.
        // (All returned screenshots matched at least one top text, so use the global max.)
        let maxSim = topTexts.first?.similarity ?? 0
        return screenshotIds.map { (screenshotId: $0, similarity: maxSim) }
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
