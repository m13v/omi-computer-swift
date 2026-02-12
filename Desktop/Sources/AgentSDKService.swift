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
        let input: [String: String]
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
