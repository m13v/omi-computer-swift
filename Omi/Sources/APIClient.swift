import Foundation

actor APIClient {
    static let shared = APIClient()

    // OMI Backend base URL (same as Flutter app)
    let baseURL = "https://api.omi.me/"

    let session: URLSession
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

    func buildHeaders(requireAuth: Bool = true) async throws -> [String: String] {
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

// MARK: - Conversation API

extension APIClient {

    /// Fetches conversations from the API with optional filtering
    func getConversations(
        limit: Int = 50,
        offset: Int = 0,
        statuses: [ConversationStatus] = [],
        includeDiscarded: Bool = false,
        startDate: Date? = nil,
        endDate: Date? = nil,
        folderId: String? = nil,
        starred: Bool? = nil
    ) async throws -> [ServerConversation] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)",
            "include_discarded=\(includeDiscarded)"
        ]

        if !statuses.isEmpty {
            let statusStrings = statuses.map { $0.rawValue }.joined(separator: ",")
            queryItems.append("statuses=\(statusStrings)")
        }

        if let startDate = startDate {
            let formatter = ISO8601DateFormatter()
            queryItems.append("start_date=\(formatter.string(from: startDate))")
        }

        if let endDate = endDate {
            let formatter = ISO8601DateFormatter()
            queryItems.append("end_date=\(formatter.string(from: endDate))")
        }

        if let folderId = folderId {
            queryItems.append("folder_id=\(folderId)")
        }

        if let starred = starred {
            queryItems.append("starred=\(starred)")
        }

        let endpoint = "v1/conversations?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Fetches a single conversation by ID
    func getConversation(id: String) async throws -> ServerConversation {
        return try await get("v1/conversations/\(id)")
    }

    /// Deletes a conversation by ID
    func deleteConversation(id: String) async throws {
        try await delete("v1/conversations/\(id)")
    }

    /// Updates the starred status of a conversation
    func setConversationStarred(id: String, starred: Bool) async throws {
        let url = URL(string: baseURL + "v1/conversations/\(id)/starred?starred=\(starred)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: true)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Searches conversations with a query
    func searchConversations(
        query: String,
        page: Int = 1,
        perPage: Int = 10,
        includeDiscarded: Bool = false
    ) async throws -> ConversationSearchResult {
        struct SearchRequest: Encodable {
            let query: String
            let page: Int
            let perPage: Int
            let includeDiscarded: Bool

            enum CodingKeys: String, CodingKey {
                case query, page
                case perPage = "per_page"
                case includeDiscarded = "include_discarded"
            }
        }

        let body = SearchRequest(
            query: query,
            page: page,
            perPage: perPage,
            includeDiscarded: includeDiscarded
        )

        return try await post("v1/conversations/search", body: body)
    }
}

// MARK: - Conversation Models (matching Flutter app)

enum ConversationStatus: String, Codable {
    case inProgress = "in_progress"
    case processing = "processing"
    case merging = "merging"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationSource: String, Codable {
    case friend
    case omi
    case workflow
    case openglass
    case screenpipe
    case sdcard
    case fieldy
    case bee
    case xor
    case frame
    case friendCom = "friend_com"
    case appleWatch = "apple_watch"
    case phone
    case desktop
    case limitless
}

struct ServerConversation: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?

    let structured: Structured
    let transcriptSegments: [TranscriptSegment]
    let geolocation: Geolocation?
    let photos: [ConversationPhoto]

    let appsResults: [AppResponse]
    let source: ConversationSource?
    let language: String?

    let status: ConversationStatus
    let discarded: Bool
    let deleted: Bool
    let isLocked: Bool
    let starred: Bool
    let folderId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case structured
        case transcriptSegments = "transcript_segments"
        case geolocation
        case photos
        case appsResults = "apps_results"
        case source
        case language
        case status
        case discarded
        case deleted
        case isLocked = "is_locked"
        case starred
        case folderId = "folder_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        structured = try container.decode(Structured.self, forKey: .structured)
        transcriptSegments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .transcriptSegments) ?? []
        geolocation = try container.decodeIfPresent(Geolocation.self, forKey: .geolocation)
        photos = try container.decodeIfPresent([ConversationPhoto].self, forKey: .photos) ?? []
        appsResults = try container.decodeIfPresent([AppResponse].self, forKey: .appsResults) ?? []
        source = try container.decodeIfPresent(ConversationSource.self, forKey: .source)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        status = try container.decodeIfPresent(ConversationStatus.self, forKey: .status) ?? .completed
        discarded = try container.decodeIfPresent(Bool.self, forKey: .discarded) ?? false
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        folderId = try container.decodeIfPresent(String.self, forKey: .folderId)
    }

    /// Returns the title from structured data, or a fallback
    var title: String {
        structured.title.isEmpty ? "Untitled Conversation" : structured.title
    }

    /// Returns the overview/summary from structured data
    var overview: String {
        structured.overview
    }

    /// Returns duration in seconds based on start/finish times or transcript
    var durationInSeconds: Int {
        if let start = startedAt, let end = finishedAt {
            return Int(end.timeIntervalSince(start))
        }
        // Fallback to transcript duration
        guard let lastSegment = transcriptSegments.last else { return 0 }
        return Int(lastSegment.end)
    }

    /// Formatted duration string (e.g., "5m 30s")
    var formattedDuration: String {
        let duration = durationInSeconds
        let minutes = duration / 60
        let seconds = duration % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    /// Full transcript as a single string
    var transcript: String {
        transcriptSegments.map { segment in
            let speaker = segment.isUser ? "You" : "Speaker \(segment.speakerId)"
            return "\(speaker): \(segment.text)"
        }.joined(separator: "\n\n")
    }
}

struct Structured: Codable {
    let title: String
    let overview: String
    let emoji: String
    let category: String
    let actionItems: [ActionItem]
    let events: [Event]

    enum CodingKeys: String, CodingKey {
        case title, overview, emoji, category
        case actionItems = "action_items"
        case events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "other"
        actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
        events = try container.decodeIfPresent([Event].self, forKey: .events) ?? []
    }
}

struct ActionItem: Codable, Identifiable {
    var id: String { description }
    let description: String
    let completed: Bool
    let deleted: Bool

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

struct Event: Codable, Identifiable {
    var id: String { title + startsAt.description }
    let title: String
    let startsAt: Date
    let duration: Int
    let description: String
    let created: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case startsAt = "starts_at"
        case duration
        case description
        case created
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        startsAt = try container.decodeIfPresent(Date.self, forKey: .startsAt) ?? Date()
        duration = try container.decodeIfPresent(Int.self, forKey: .duration) ?? 0
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        created = try container.decodeIfPresent(Bool.self, forKey: .created) ?? false
    }
}

struct TranscriptSegment: Codable, Identifiable {
    let id: String
    let text: String
    let speaker: String?
    let isUser: Bool
    let personId: String?
    let start: Double
    let end: Double

    var speakerId: Int {
        guard let speaker = speaker else { return 0 }
        let parts = speaker.split(separator: "_")
        if parts.count > 1, let id = Int(parts[1]) {
            return id
        }
        return 0
    }

    enum CodingKeys: String, CodingKey {
        case id, text, speaker
        case isUser = "is_user"
        case personId = "person_id"
        case start, end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
        isUser = try container.decodeIfPresent(Bool.self, forKey: .isUser) ?? false
        personId = try container.decodeIfPresent(String.self, forKey: .personId)
        start = try container.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try container.decodeIfPresent(Double.self, forKey: .end) ?? 0
    }

    /// Formatted timestamp string (e.g., "00:01:30 - 00:01:45")
    var timestampString: String {
        let startTime = formatTime(start)
        let endTime = formatTime(end)
        return "\(startTime) - \(endTime)"
    }

    private func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

struct Geolocation: Codable {
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let locationType: String?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, address
        case locationType = "location_type"
    }
}

struct ConversationPhoto: Codable, Identifiable {
    let id: String
    let base64: String
    let description: String?
    let createdAt: Date
    let discarded: Bool

    enum CodingKeys: String, CodingKey {
        case id, base64, description
        case createdAt = "created_at"
        case discarded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        base64 = try container.decodeIfPresent(String.self, forKey: .base64) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        discarded = try container.decodeIfPresent(Bool.self, forKey: .discarded) ?? false
    }
}

struct AppResponse: Codable, Identifiable {
    var id: String { appId ?? UUID().uuidString }
    let appId: String?
    let content: String

    enum CodingKeys: String, CodingKey {
        case appId = "app_id"
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appId = try container.decodeIfPresent(String.self, forKey: .appId)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
    }
}

struct ConversationSearchResult: Codable {
    let items: [ServerConversation]
    let currentPage: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case items
        case currentPage = "current_page"
        case totalPages = "total_pages"
    }
}

// MARK: - Common API Models

struct UserProfile: Codable {
    let id: String
    let email: String?
    let name: String?
    let createdAt: Date?
}
