import Foundation

// MARK: - Gemini API Request/Response Types

struct GeminiRequest: Encodable {
    let contents: [Content]
    let systemInstruction: SystemInstruction?
    let generationConfig: GenerationConfig?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
    }

    struct Content: Encodable {
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        enum CodingKeys: String, CodingKey {
            case text
            case inlineData = "inline_data"
        }

        init(text: String) {
            self.text = text
            self.inlineData = nil
        }

        init(mimeType: String, data: String) {
            self.text = nil
            self.inlineData = InlineData(mimeType: mimeType, data: data)
        }
    }

    struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    struct SystemInstruction: Encodable {
        let parts: [TextPart]

        struct TextPart: Encodable {
            let text: String
        }
    }

    struct GenerationConfig: Encodable {
        let responseMimeType: String
        let responseSchema: ResponseSchema?

        enum CodingKeys: String, CodingKey {
            case responseMimeType = "response_mime_type"
            case responseSchema = "response_schema"
        }

        struct ResponseSchema: Encodable {
            let type: String
            let properties: [String: Property]
            let required: [String]

            struct Property: Encodable {
                let type: String
                let `enum`: [String]?
                let description: String?
                let items: Items?
                let nestedProperties: [String: Property]?
                let nestedRequired: [String]?

                enum CodingKeys: String, CodingKey {
                    case type
                    case `enum`
                    case description
                    case items
                    case nestedProperties = "properties"
                    case nestedRequired = "required"
                }

                init(type: String, enum: [String]? = nil, description: String? = nil, items: Items? = nil) {
                    self.type = type
                    self.enum = `enum`
                    self.description = description
                    self.items = items
                    self.nestedProperties = nil
                    self.nestedRequired = nil
                }

                /// Initialize an object property with nested properties
                init(type: String, description: String? = nil, properties: [String: Property], required: [String]) {
                    self.type = type
                    self.enum = nil
                    self.description = description
                    self.items = nil
                    self.nestedProperties = properties
                    self.nestedRequired = required
                }

                struct Items: Encodable {
                    let type: String
                    let properties: [String: Property]?
                    let required: [String]?
                }
            }
        }
    }
}

struct GeminiResponse: Decodable {
    let candidates: [Candidate]?
    let error: GeminiError?

    struct Candidate: Decodable {
        let content: Content?

        struct Content: Decodable {
            let parts: [Part]?

            struct Part: Decodable {
                let text: String?
            }
        }
    }

    struct GeminiError: Decodable {
        let message: String
    }
}

// MARK: - GeminiClient

/// Low-level client for communicating with the Gemini API
actor GeminiClient {
    private let apiKey: String
    private let model: String

    enum GeminiClientError: LocalizedError {
        case missingAPIKey
        case networkError(Error)
        case invalidResponse
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "GEMINI_API_KEY not set"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from Gemini API"
            case .apiError(let message):
                return "API error: \(message)"
            }
        }
    }

    init(apiKey: String? = nil, model: String = "gemini-3-flash-preview") throws {
        guard let key = apiKey ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
            throw GeminiClientError.missingAPIKey
        }
        self.apiKey = key
        self.model = model
    }

    /// Send a request to the Gemini API with an image
    /// - Parameters:
    ///   - prompt: Text prompt to send
    ///   - imageData: JPEG image data to analyze
    ///   - systemPrompt: System instructions for the model
    ///   - responseSchema: JSON schema for structured output
    /// - Returns: The text response from the model
    func sendRequest(
        prompt: String,
        imageData: Data,
        systemPrompt: String,
        responseSchema: GeminiRequest.GenerationConfig.ResponseSchema
    ) async throws -> String {
        let base64Data = imageData.base64EncodedString()

        let request = GeminiRequest(
            contents: [
                GeminiRequest.Content(parts: [
                    GeminiRequest.Part(text: prompt),
                    GeminiRequest.Part(mimeType: "image/jpeg", data: base64Data)
                ])
            ],
            systemInstruction: GeminiRequest.SystemInstruction(
                parts: [GeminiRequest.SystemInstruction.TextPart(text: systemPrompt)]
            ),
            generationConfig: GeminiRequest.GenerationConfig(
                responseMimeType: "application/json",
                responseSchema: responseSchema
            )
        )

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)

        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        if let error = response.error {
            throw GeminiClientError.apiError(error.message)
        }

        guard let text = response.candidates?.first?.content?.parts?.first?.text else {
            throw GeminiClientError.invalidResponse
        }

        return text
    }

    /// Send a text-only request to the Gemini API
    /// - Parameters:
    ///   - prompt: Text prompt to send
    ///   - systemPrompt: System instructions for the model
    /// - Returns: The text response from the model
    func sendTextRequest(
        prompt: String,
        systemPrompt: String
    ) async throws -> String {
        let request = GeminiRequest(
            contents: [
                GeminiRequest.Content(parts: [
                    GeminiRequest.Part(text: prompt)
                ])
            ],
            systemInstruction: GeminiRequest.SystemInstruction(
                parts: [GeminiRequest.SystemInstruction.TextPart(text: systemPrompt)]
            ),
            generationConfig: nil
        )

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, _) = try await URLSession.shared.data(for: urlRequest)

        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        if let error = response.error {
            throw GeminiClientError.apiError(error.message)
        }

        guard let text = response.candidates?.first?.content?.parts?.first?.text else {
            throw GeminiClientError.invalidResponse
        }

        return text
    }

    /// Send a multi-turn chat request with streaming response
    /// - Parameters:
    ///   - messages: Array of chat messages (role: user/model, text)
    ///   - systemPrompt: System instructions for the model
    ///   - onChunk: Callback for each text chunk received
    /// - Returns: The complete text response
    func sendChatStreamRequest(
        messages: [ChatMessage],
        systemPrompt: String,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        // Build contents from chat messages
        let contents = messages.map { message in
            GeminiChatRequest.Content(
                role: message.role,
                parts: [GeminiChatRequest.Part(text: message.text)]
            )
        }

        let request = GeminiChatRequest(
            contents: contents,
            systemInstruction: GeminiChatRequest.SystemInstruction(
                parts: [GeminiChatRequest.SystemInstruction.TextPart(text: systemPrompt)]
            ),
            generationConfig: GeminiChatRequest.GenerationConfig(
                temperature: 0.7,
                maxOutputTokens: 8192
            )
        )

        // Use streamGenerateContent endpoint for streaming
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300
        urlRequest.httpBody = try JSONEncoder().encode(request)

        var fullText = ""

        // Use URLSession bytes for streaming
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiClientError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            throw GeminiClientError.apiError("HTTP \(httpResponse.statusCode)")
        }

        // Parse SSE stream
        for try await line in bytes.lines {
            // SSE format: "data: {json}"
            if line.hasPrefix("data: ") {
                let jsonString = String(line.dropFirst(6))
                if let data = jsonString.data(using: .utf8) {
                    if let chunk = try? JSONDecoder().decode(GeminiStreamChunk.self, from: data) {
                        if let text = chunk.candidates?.first?.content?.parts?.first?.text {
                            fullText += text
                            onChunk(text)
                        }
                    }
                }
            }
        }

        return fullText
    }

    /// Chat message for multi-turn conversation
    struct ChatMessage {
        let role: String  // "user" or "model"
        let text: String
    }
}

// MARK: - Gemini Chat Request (multi-turn with roles)

struct GeminiChatRequest: Encodable {
    let contents: [Content]
    let systemInstruction: SystemInstruction?
    let generationConfig: GenerationConfig?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
        case generationConfig = "generation_config"
    }

    struct Content: Encodable {
        let role: String  // "user" or "model"
        let parts: [Part]
    }

    struct Part: Encodable {
        let text: String
    }

    struct SystemInstruction: Encodable {
        let parts: [TextPart]

        struct TextPart: Encodable {
            let text: String
        }
    }

    struct GenerationConfig: Encodable {
        let temperature: Double?
        let maxOutputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case maxOutputTokens = "max_output_tokens"
        }
    }
}

// MARK: - Gemini Stream Chunk Response

struct GeminiStreamChunk: Decodable {
    let candidates: [Candidate]?

    struct Candidate: Decodable {
        let content: Content?

        struct Content: Decodable {
            let parts: [Part]?

            struct Part: Decodable {
                let text: String?
            }
        }
    }
}
