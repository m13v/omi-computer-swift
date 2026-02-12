import Foundation

@MainActor
class AgentSDKService: ObservableObject {
    static let shared = AgentSDKService()

    private let baseURL = "http://localhost:8081"
    private let session: URLSession

    @Published private(set) var isHealthy = false

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        Task { await startHealthCheck() }
    }

    // MARK: - Health Check

    private func startHealthCheck() async {
        while true {
            do {
                let url = URL(string: "\(baseURL)/health")!
                let (_, response) = try await session.data(from: url)
                isHealthy = (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                isHealthy = false
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - Agent Execution

    struct AgentRequest: Codable {
        let prompt: String
        let context: [String: String]?
    }

    struct AgentResponse: Codable {
        let success: Bool
        let response: String?
        let error: String?
    }

    // MARK: - Conversational Chat (with tool use)

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    struct ToolCall: Codable {
        let name: String
        let input: ToolInput

        struct ToolInput: Codable {
            private let storage: [String: AnyCodable]

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let dict = try container.decode([String: AnyCodable].self)
                self.storage = dict
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(storage)
            }

            subscript(key: String) -> Any? {
                return storage[key]?.value
            }

            func string(_ key: String) -> String? {
                return storage[key]?.value as? String
            }

            func stringArray(_ key: String) -> [String]? {
                return storage[key]?.value as? [String]
            }
        }
    }

    // Helper for decoding arbitrary JSON values
    struct AnyCodable: Codable {
        let value: Any

        init(_ value: Any) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int.self) {
                value = int
            } else if let double = try? container.decode(Double.self) {
                value = double
            } else if let bool = try? container.decode(Bool.self) {
                value = bool
            } else if let array = try? container.decode([AnyCodable].self) {
                value = array.map { $0.value }
            } else if let dict = try? container.decode([String: AnyCodable].self) {
                value = dict.mapValues { $0.value }
            } else {
                value = NSNull()
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()

            switch value {
            case let string as String:
                try container.encode(string)
            case let int as Int:
                try container.encode(int)
            case let double as Double:
                try container.encode(double)
            case let bool as Bool:
                try container.encode(bool)
            case let array as [Any]:
                try container.encode(array.map { AnyCodable($0) })
            case let dict as [String: Any]:
                try container.encode(dict.mapValues { AnyCodable($0) })
            default:
                try container.encodeNil()
            }
        }
    }

    struct ChatRequest: Codable {
        let messages: [ChatMessage]
        let collected_data: [String: String]?

        enum CodingKeys: String, CodingKey {
            case messages
            case collected_data = "collected_data"
        }
    }

    struct ChatResponse: Codable {
        let success: Bool
        let response: String?
        let tool_calls: [ToolCall]?
        let stop_reason: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case success, response, error
            case tool_calls = "tool_calls"
            case stop_reason = "stop_reason"
        }
    }

    func chat(messages: [(role: String, content: String)], collectedData: [String: String]? = nil) async throws -> (response: String, toolCalls: [ToolCall]) {
        guard isHealthy else {
            throw AgentSDKError.serviceUnavailable
        }

        let url = URL(string: "\(baseURL)/agent/chat")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatMessages = messages.map { ChatMessage(role: $0.role, content: $0.content) }
        let body = ChatRequest(messages: chatMessages, collected_data: collectedData)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AgentSDKError.invalidResponse
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)

        guard chatResponse.success else {
            throw AgentSDKError.agentFailed(message: chatResponse.error ?? "Unknown error")
        }

        let responseText = chatResponse.response ?? ""
        let toolCalls = chatResponse.tool_calls ?? []

        return (responseText, toolCalls)
    }

    func runAgent(prompt: String, context: [String: String]? = nil) async throws -> String {
        guard isHealthy else {
            throw AgentSDKError.serviceUnavailable
        }

        let url = URL(string: "\(baseURL)/agent/run")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = AgentRequest(prompt: prompt, context: context)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AgentSDKError.invalidResponse
        }

        let agentResponse = try JSONDecoder().decode(AgentResponse.self, from: data)

        guard agentResponse.success, let responseText = agentResponse.response else {
            throw AgentSDKError.agentFailed(message: agentResponse.error ?? "Unknown error")
        }

        return responseText
    }
}

enum AgentSDKError: LocalizedError {
    case serviceUnavailable
    case invalidResponse
    case agentFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return "Agent service is not available"
        case .invalidResponse:
            return "Invalid response from agent service"
        case .agentFailed(let message):
            return "Agent execution failed: \(message)"
        }
    }
}
