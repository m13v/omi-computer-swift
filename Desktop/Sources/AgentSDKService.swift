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
