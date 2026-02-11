import Foundation
import Accelerate

/// Actor-based service for embeddings with support for both Gemini (768-dim) and OpenAI (3072-dim)
actor EmbeddingService {
    static let shared = EmbeddingService()

    enum EmbeddingModel {
        case gemini  // 768 dimensions - for action items
        case openai  // 3072 dimensions - for screenshots

        var dimensions: Int {
            switch self {
            case .gemini: return 768
            case .openai: return 3072
            }
        }

        var modelName: String {
            switch self {
            case .gemini: return "gemini-embedding-001"
            case .openai: return "text-embedding-3-large"
            }
        }
    }

    private let geminiApiKey: String?
    private let openaiApiKey: String?

    /// In-memory index: action_item.id -> normalized embedding
    private var index: [Int64: [Float]] = [:]
    private var isIndexLoaded = false

    private init() {
        self.geminiApiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        self.openaiApiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
    }

    // MARK: - Embedding API

    /// Generate embedding for a single text
    /// - Parameters:
    ///   - text: Text to embed
    ///   - model: Embedding model to use (default: .gemini for backward compatibility)
    ///   - taskType: Optional Gemini task type (e.g. "RETRIEVAL_DOCUMENT", "RETRIEVAL_QUERY")
    func embed(text: String, model: EmbeddingModel = .gemini, taskType: String? = nil) async throws -> [Float] {
        switch model {
        case .gemini:
            return try await embedGemini(text: text, taskType: taskType)
        case .openai:
            return try await embedOpenAI(text: text)
        }
    }

    /// Gemini embedding (768 dimensions)
    private func embedGemini(text: String, taskType: String? = nil) async throws -> [Float] {
        guard let apiKey = geminiApiKey else {
            throw EmbeddingError.missingAPIKey(provider: "Gemini")
        }

        let modelName = EmbeddingModel.gemini.modelName
        var requestBody: [String: Any] = [
            "model": "models/\(modelName)",
            "content": [
                "parts": [["text": text]]
            ]
        ]
        if let taskType = taskType {
            requestBody["taskType"] = taskType
        }

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):embedContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embedding = json["embedding"] as? [String: Any],
              let values = embedding["values"] as? [Double] else {
            throw EmbeddingError.invalidResponse
        }

        let floats = values.map { Float($0) }
        return normalize(floats)
    }

    /// OpenAI embedding (3072 dimensions)
    private func embedOpenAI(text: String) async throws -> [Float] {
        guard let apiKey = openaiApiKey else {
            throw EmbeddingError.missingAPIKey(provider: "OpenAI")
        }

        let requestBody: [String: Any] = [
            "input": text,
            "model": EmbeddingModel.openai.modelName,
            "encoding_format": "float"
        ]

        let url = URL(string: "https://api.openai.com/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstItem = dataArray.first,
              let embedding = firstItem["embedding"] as? [Double] else {
            throw EmbeddingError.invalidResponse
        }

        let floats = embedding.map { Float($0) }
        return normalize(floats)
    }

    /// Batch embed multiple texts (up to 100 per call)
    /// - Parameters:
    ///   - texts: Texts to embed
    ///   - model: Embedding model to use (default: .gemini for backward compatibility)
    ///   - taskType: Optional Gemini task type (e.g. "RETRIEVAL_DOCUMENT", "RETRIEVAL_QUERY")
    func embedBatch(texts: [String], model: EmbeddingModel = .gemini, taskType: String? = nil) async throws -> [[Float]] {
        switch model {
        case .gemini:
            return try await embedBatchGemini(texts: texts, taskType: taskType)
        case .openai:
            return try await embedBatchOpenAI(texts: texts)
        }
    }

    /// Gemini batch embedding (768 dimensions)
    private func embedBatchGemini(texts: [String], taskType: String? = nil) async throws -> [[Float]] {
        guard let apiKey = geminiApiKey else {
            throw EmbeddingError.missingAPIKey(provider: "Gemini")
        }

        let modelName = EmbeddingModel.gemini.modelName
        let requests = texts.map { text in
            var req: [String: Any] = [
                "model": "models/\(modelName)",
                "content": [
                    "parts": [["text": text]]
                ]
            ]
            if let taskType = taskType {
                req["taskType"] = taskType
            }
            return req
        }

        let requestBody: [String: Any] = ["requests": requests]

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):batchEmbedContents?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let embeddings = json["embeddings"] as? [[String: Any]] else {
            throw EmbeddingError.invalidResponse
        }

        return embeddings.compactMap { embedding in
            guard let values = embedding["values"] as? [Double] else { return nil }
            return normalize(values.map { Float($0) })
        }
    }

    /// OpenAI batch embedding (3072 dimensions) - processes texts sequentially to avoid rate limits
    private func embedBatchOpenAI(texts: [String]) async throws -> [[Float]] {
        guard let apiKey = openaiApiKey else {
            throw EmbeddingError.missingAPIKey(provider: "OpenAI")
        }

        // OpenAI supports batch requests with multiple inputs
        let requestBody: [String: Any] = [
            "input": texts,
            "model": EmbeddingModel.openai.modelName,
            "encoding_format": "float"
        ]

        let url = URL(string: "https://api.openai.com/v1/embeddings")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            throw EmbeddingError.invalidResponse
        }

        return dataArray.compactMap { item in
            guard let embedding = item["embedding"] as? [Double] else { return nil }
            return normalize(embedding.map { Float($0) })
        }
    }

    // MARK: - In-Memory Index

    /// Load all embeddings from SQLite into memory
    func loadIndex() async {
        do {
            let rows = try await ActionItemStorage.shared.getAllEmbeddings()
            index.removeAll(keepingCapacity: true)
            for (id, data) in rows {
                if let floats = dataToFloats(data) {
                    index[id] = floats
                }
            }
            isIndexLoaded = true
            log("EmbeddingService: Loaded \(index.count) embeddings into memory")
        } catch {
            logError("EmbeddingService: Failed to load index", error: error)
        }
    }

    /// Add a single embedding to the in-memory index
    func addToIndex(id: Int64, embedding: [Float]) {
        index[id] = embedding
    }

    /// Remove an entry from the index
    func removeFromIndex(id: Int64) {
        index.removeValue(forKey: id)
    }

    /// Search for similar items using cosine similarity via Accelerate/vDSP
    func searchSimilar(query: [Float], topK: Int = 10) -> [(id: Int64, similarity: Float)] {
        guard !index.isEmpty else { return [] }

        var results: [(id: Int64, similarity: Float)] = []
        results.reserveCapacity(index.count)

        for (id, stored) in index {
            let sim = cosineSimilarity(query, stored)
            results.append((id, sim))
        }

        // Sort descending by similarity and take topK
        results.sort { $0.similarity > $1.similarity }
        return Array(results.prefix(topK))
    }

    /// Whether the index has been loaded
    var indexLoaded: Bool { isIndexLoaded }

    /// Number of items in the index
    var indexSize: Int { index.count }

    // MARK: - Backfill

    /// Batch-embed all tasks missing embeddings
    func backfillIfNeeded() async {
        let batchSize = 100
        var totalProcessed = 0

        do {
            while true {
                let items = try await ActionItemStorage.shared.getItemsMissingEmbeddings(limit: batchSize)
                if items.isEmpty { break }

                let texts = items.map { $0.description }
                let embeddings = try await embedBatch(texts: texts)

                for (i, embedding) in embeddings.enumerated() where i < items.count {
                    let item = items[i]
                    let data = floatsToData(embedding)
                    try await ActionItemStorage.shared.updateEmbedding(id: item.id, embedding: data)
                    addToIndex(id: item.id, embedding: embedding)
                }

                totalProcessed += items.count
                log("EmbeddingService: Backfill progress: \(totalProcessed) items")

                // Small delay to avoid rate limiting
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }

            if totalProcessed > 0 {
                log("EmbeddingService: Backfill complete — \(totalProcessed) items embedded")
            }
        } catch {
            logError("EmbeddingService: Backfill failed after \(totalProcessed) items", error: error)
        }
    }

    // MARK: - Helpers

    /// Cosine similarity using Accelerate vDSP for performance
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        // Vectors are pre-normalized, so dot product = cosine similarity
        return dot
    }

    /// Normalize a vector to unit length
    private func normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    /// Convert [Float] to Data (for SQLite BLOB storage)
    func floatsToData(_ floats: [Float]) -> Data {
        return floats.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    /// Convert Data (BLOB) back to [Float]
    /// Supports both 768-dim (Gemini) and 3072-dim (OpenAI) embeddings
    func dataToFloats(_ data: Data) -> [Float]? {
        let floatSize = MemoryLayout<Float>.size
        let floatCount = data.count / floatSize

        // Accept both 768-dim (Gemini) and 3072-dim (OpenAI) embeddings
        guard floatCount == EmbeddingModel.gemini.dimensions ||
              floatCount == EmbeddingModel.openai.dimensions else {
            return nil
        }

        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - Errors

    enum EmbeddingError: LocalizedError {
        case missingAPIKey(provider: String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider): return "\(provider) API key not set"
            case .invalidResponse: return "Invalid embedding API response"
            }
        }
    }
}
