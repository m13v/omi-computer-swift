import Foundation

actor APIClient {
    static let shared = APIClient()

    // OMI Backend base URL (same as Flutter app)
    private let baseURL = "https://api.omi.me/"

    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Request Building

    private func buildHeaders(requireAuth: Bool = true) async throws -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "X-App-Platform": "macos",
            "X-Request-Start-Time": String(Date().timeIntervalSince1970),
        ]

        if requireAuth {
            let authService = await AuthService.shared
            let authHeader = try await authService.getAuthHeader()
            headers["Authorization"] = authHeader
        }

        return headers
    }

    // MARK: - HTTP Methods

    func get<T: Decodable>(
        _ endpoint: String,
        requireAuth: Bool = true
    ) async throws -> T {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: requireAuth)

        return try await performRequest(request)
    }

    func post<T: Decodable, B: Encodable>(
        _ endpoint: String,
        body: B,
        requireAuth: Bool = true
    ) async throws -> T {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: requireAuth)
        request.httpBody = try JSONEncoder().encode(body)

        return try await performRequest(request)
    }

    func post<T: Decodable>(
        _ endpoint: String,
        requireAuth: Bool = true
    ) async throws -> T {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: requireAuth)

        return try await performRequest(request)
    }

    func delete(
        _ endpoint: String,
        requireAuth: Bool = true
    ) async throws {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: requireAuth)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    // MARK: - Request Execution

    private func performRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        // Handle 401 - token might be expired
        if httpResponse.statusCode == 401 {
            // Try to refresh token and retry once
            let authService = await AuthService.shared
            _ = try await authService.getIdToken(forceRefresh: true)

            var retryRequest = request
            retryRequest.setValue(try await authService.getAuthHeader(), forHTTPHeaderField: "Authorization")

            let (retryData, retryResponse) = try await session.data(for: retryRequest)

            guard let retryHttpResponse = retryResponse as? HTTPURLResponse else {
                throw APIError.invalidResponse
            }

            if retryHttpResponse.statusCode == 401 {
                throw APIError.unauthorized
            }

            guard (200...299).contains(retryHttpResponse.statusCode) else {
                throw APIError.httpError(statusCode: retryHttpResponse.statusCode)
            }

            return try decoder.decode(T.self, from: retryData)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidResponse
    case unauthorized
    case httpError(statusCode: Int)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Unauthorized - please sign in again"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

// MARK: - Common API Models (matching Flutter app)

struct UserProfile: Codable {
    let id: String
    let email: String?
    let name: String?
    let createdAt: Date?
}

struct Conversation: Codable, Identifiable {
    let id: String
    let title: String?
    let summary: String?
    let createdAt: Date?
    let duration: Int?
    let status: String?
}

struct ConversationsResponse: Codable {
    let conversations: [Conversation]
}
