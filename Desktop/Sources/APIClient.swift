import Foundation

actor APIClient {
    static let shared = APIClient()

    // OMI Backend base URL - loaded from .env file (OMI_API_URL)
    // Production URL is set in .env.app, dev URL is set by run.sh
    var baseURL: String {
        // First check getenv() for values set by setenv() in loadEnvironment()
        if let cString = getenv("OMI_API_URL"), let url = String(validatingUTF8: cString), !url.isEmpty {
            return url.hasSuffix("/") ? url : url + "/"
        }
        // Fallback to ProcessInfo (launch-time snapshot)
        if let envURL = ProcessInfo.processInfo.environment["OMI_API_URL"], !envURL.isEmpty {
            return envURL.hasSuffix("/") ? envURL : envURL + "/"
        }
        // No hardcoded default - must be set via .env file
        fatalError("OMI_API_URL not set. Ensure .env file is present in app bundle.")
    }

    let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)

        self.decoder = JSONDecoder()
        // Note: Don't use .convertFromSnakeCase - it conflicts with explicit CodingKeys
        // Use custom date strategy to handle ISO8601 with fractional seconds
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try with fractional seconds first (API returns dates like "2026-01-25T22:51:07.159249Z")
            let isoWithFractional = ISO8601DateFormatter()
            isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoWithFractional.date(from: dateString) {
                return date
            }

            // Fallback to standard ISO8601 without fractional seconds
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: dateString) {
                return date
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }
    }

    // MARK: - Request Building

    func buildHeaders(requireAuth: Bool = true) async throws -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "X-App-Platform": "macos",
            "X-Request-Start-Time": String(Date().timeIntervalSince1970),
        ]

        if requireAuth {
            let authService = AuthService.shared
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
        requireAuth: Bool = true,
        customBaseURL: String? = nil
    ) async throws -> T {
        let base = customBaseURL ?? baseURL
        let url = URL(string: base + endpoint)!
        log("APIClient: POST \(url.absoluteString)")
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
            let authService = AuthService.shared
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

        do {
            return try decoder.decode(T.self, from: data)
        } catch let decodingError as DecodingError {
            // Log detailed decoding error for debugging
            switch decodingError {
            case .keyNotFound(let key, let context):
                logError("Decoding error - key '\(key.stringValue)' not found: \(context.debugDescription)", error: decodingError)
            case .typeMismatch(let type, let context):
                logError("Decoding error - type mismatch for \(type): \(context.debugDescription)", error: decodingError)
            case .valueNotFound(let type, let context):
                logError("Decoding error - value not found for \(type): \(context.debugDescription)", error: decodingError)
            case .dataCorrupted(let context):
                logError("Decoding error - data corrupted: \(context.debugDescription)", error: decodingError)
            @unknown default:
                logError("Decoding error", error: decodingError)
            }
            throw decodingError
        }
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

    /// Updates the title of a conversation
    func updateConversationTitle(id: String, title: String) async throws {
        struct TitleUpdate: Encodable {
            let title: String
        }

        let url = URL(string: baseURL + "v1/conversations/\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: true)
        request.httpBody = try JSONEncoder().encode(TitleUpdate(title: title))

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

    /// Gets the total count of conversations
    func getConversationsCount(
        includeDiscarded: Bool = false,
        statuses: [ConversationStatus] = [.completed, .processing]
    ) async throws -> Int {
        var queryItems: [String] = [
            "include_discarded=\(includeDiscarded)"
        ]

        if !statuses.isEmpty {
            let statusStrings = statuses.map { $0.rawValue }.joined(separator: ",")
            queryItems.append("statuses=\(statusStrings)")
        }

        let endpoint = "v1/conversations/count?\(queryItems.joined(separator: "&"))"

        struct CountResponse: Decodable {
            let count: Int
        }

        let response: CountResponse = try await get(endpoint)
        return response.count
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
    case plaud
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ConversationSource(rawValue: rawValue) ?? .unknown
    }
}

struct ServerConversation: Codable, Identifiable {
    let id: String
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?

    var structured: Structured
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
    var starred: Bool
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
    var title: String
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

// MARK: - Memory Models

enum MemoryCategory: String, Codable, CaseIterable {
    case system
    case interesting
    case manual

    var displayName: String {
        switch self {
        case .system: return "System"
        case .interesting: return "Interesting"
        case .manual: return "Manual"
        }
    }

    var icon: String {
        switch self {
        case .system: return "gearshape"
        case .interesting: return "sparkles"
        case .manual: return "square.and.pencil"
        }
    }
}

struct ServerMemory: Codable, Identifiable {
    let id: String
    let content: String
    let category: MemoryCategory
    let createdAt: Date
    let updatedAt: Date
    let conversationId: String?
    let reviewed: Bool
    let userReview: Bool?
    let visibility: String
    let manuallyAdded: Bool
    let scoring: String?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case id, content, category, reviewed, visibility, scoring, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case conversationId = "conversation_id"
        case userReview = "user_review"
        case manuallyAdded = "manually_added"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        category = try container.decodeIfPresent(MemoryCategory.self, forKey: .category) ?? .system
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        reviewed = try container.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        userReview = try container.decodeIfPresent(Bool.self, forKey: .userReview)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility) ?? "private"
        manuallyAdded = try container.decodeIfPresent(Bool.self, forKey: .manuallyAdded) ?? false
        scoring = try container.decodeIfPresent(String.self, forKey: .scoring)
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    var isPublic: Bool {
        visibility == "public"
    }

    /// Human-readable source name
    var sourceName: String? {
        guard let source = source else { return nil }
        switch source {
        case "omi": return "OMI"
        case "desktop": return "Desktop"
        case "phone": return "Phone"
        case "frame": return "Frame"
        case "friend", "friend_com": return "Friend"
        case "apple_watch": return "Apple Watch"
        case "bee": return "Bee"
        case "plaud": return "Plaud"
        case "limitless": return "Limitless"
        case "screenpipe": return "Screenpipe"
        case "workflow": return "Integration"
        case "openglass": return "OpenGlass"
        default: return source.capitalized
        }
    }

    /// SF Symbol for source device
    var sourceIcon: String {
        guard let source = source else { return "questionmark.circle" }
        switch source {
        case "omi": return "wave.3.right.circle"
        case "desktop": return "desktopcomputer"
        case "phone": return "iphone"
        case "frame": return "eyeglasses"
        case "friend", "friend_com": return "person.wave.2"
        case "apple_watch": return "applewatch"
        case "bee": return "ant"
        case "plaud": return "mic"
        case "limitless": return "infinity"
        case "screenpipe": return "rectangle.on.rectangle"
        case "workflow": return "arrow.triangle.branch"
        case "openglass": return "eyeglasses"
        default: return "circle"
        }
    }
}

// MARK: - Create Conversation API

extension APIClient {

    /// Request model for creating a conversation from transcript segments
    struct CreateConversationFromSegmentsRequest: Encodable {
        let transcriptSegments: [TranscriptSegmentRequest]
        let source: String
        let startedAt: String
        let finishedAt: String
        let language: String
        let timezone: String

        enum CodingKeys: String, CodingKey {
            case transcriptSegments = "transcript_segments"
            case source
            case startedAt = "started_at"
            case finishedAt = "finished_at"
            case language
            case timezone
        }
    }

    struct TranscriptSegmentRequest: Encodable {
        let text: String
        let speaker: String
        let speakerId: Int
        let isUser: Bool
        let start: Double
        let end: Double

        enum CodingKeys: String, CodingKey {
            case text, speaker
            case speakerId = "speaker_id"
            case isUser = "is_user"
            case start, end
        }
    }

    struct CreateConversationResponse: Decodable {
        let id: String
        let status: String
        let discarded: Bool
    }

    /// Creates a conversation from transcript segments
    /// Endpoint: POST /v1/conversations/from-segments (local backend)
    func createConversationFromSegments(
        segments: [TranscriptSegmentRequest],
        startedAt: Date,
        finishedAt: Date,
        language: String = "en",
        timezone: String = "UTC"
    ) async throws -> CreateConversationResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let request = CreateConversationFromSegmentsRequest(
            transcriptSegments: segments,
            source: "desktop",
            startedAt: formatter.string(from: startedAt),
            finishedAt: formatter.string(from: finishedAt),
            language: language,
            timezone: timezone
        )

        return try await post("v1/conversations/from-segments", body: request)
    }
}

// MARK: - Memories API

extension APIClient {

    /// Fetches memories from the API
    func getMemories(limit: Int = 100, offset: Int = 0) async throws -> [ServerMemory] {
        let endpoint = "v3/memories?limit=\(limit)&offset=\(offset)"
        return try await get(endpoint)
    }

    /// Creates a new manual memory
    func createMemory(content: String, visibility: String = "private") async throws -> CreateMemoryResponse {
        struct CreateRequest: Encodable {
            let content: String
            let visibility: String
        }
        let body = CreateRequest(content: content, visibility: visibility)
        return try await post("v3/memories", body: body)
    }

    /// Deletes a memory by ID
    func deleteMemory(id: String) async throws {
        try await delete("v3/memories/\(id)")
    }

    /// Edits a memory's content
    func editMemory(id: String, content: String) async throws {
        struct EditRequest: Encodable {
            let value: String
        }
        let body = EditRequest(value: content)
        let _: MemoryStatusResponse = try await patch("v3/memories/\(id)", body: body)
    }

    /// Updates a memory's visibility
    func updateMemoryVisibility(id: String, visibility: String) async throws {
        struct VisibilityRequest: Encodable {
            let value: String
        }
        let body = VisibilityRequest(value: visibility)
        let _: MemoryStatusResponse = try await patch("v3/memories/\(id)/visibility", body: body)
    }

    /// Reviews/approves a memory
    func reviewMemory(id: String, value: Bool) async throws {
        struct ReviewRequest: Encodable {
            let value: Bool
        }
        let body = ReviewRequest(value: value)
        let _: MemoryStatusResponse = try await post("v3/memories/\(id)/review", body: body)
    }

    // MARK: - PATCH helper

    func patch<T: Decodable, B: Encodable>(
        _ endpoint: String,
        body: B,
        requireAuth: Bool = true
    ) async throws -> T {
        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: requireAuth)
        request.httpBody = try JSONEncoder().encode(body)

        return try await performPatchRequest(request)
    }

    private func performPatchRequest<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(T.self, from: data)
    }
}

struct CreateMemoryResponse: Codable {
    let id: String
    let message: String
}

struct MemoryStatusResponse: Codable {
    let status: String
}

// MARK: - Common API Models

struct UserProfile: Codable {
    let id: String
    let email: String?
    let name: String?
    let createdAt: Date?
}

// MARK: - Action Items API

extension APIClient {

    /// Fetches action items from the API with optional filtering
    func getActionItems(
        limit: Int = 100,
        offset: Int = 0,
        completed: Bool? = nil
    ) async throws -> [TaskActionItem] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)"
        ]

        if let completed = completed {
            queryItems.append("completed=\(completed)")
        }

        let endpoint = "v1/action-items?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Updates an action item
    func updateActionItem(
        id: String,
        completed: Bool? = nil,
        description: String? = nil,
        dueAt: Date? = nil
    ) async throws -> TaskActionItem {
        struct UpdateRequest: Encodable {
            let completed: Bool?
            let description: String?
            let dueAt: String?

            enum CodingKeys: String, CodingKey {
                case completed, description
                case dueAt = "due_at"
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let request = UpdateRequest(
            completed: completed,
            description: description,
            dueAt: dueAt.map { formatter.string(from: $0) }
        )

        return try await patch("v1/action-items/\(id)", body: request)
    }

    /// Deletes an action item
    func deleteActionItem(id: String) async throws {
        try await delete("v1/action-items/\(id)")
    }

    /// Creates a new action item
    func createActionItem(
        description: String,
        dueAt: Date? = nil,
        source: String? = nil,
        priority: String? = nil,
        metadata: [String: Any]? = nil
    ) async throws -> TaskActionItem {
        struct CreateRequest: Encodable {
            let description: String
            let dueAt: String?
            let source: String?
            let priority: String?
            let metadata: String?

            enum CodingKeys: String, CodingKey {
                case description
                case dueAt = "due_at"
                case source, priority, metadata
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var metadataString: String? = nil
        if let metadata = metadata {
            if let data = try? JSONSerialization.data(withJSONObject: metadata),
               let str = String(data: data, encoding: .utf8) {
                metadataString = str
            }
        }

        let request = CreateRequest(
            description: description,
            dueAt: dueAt.map { formatter.string(from: $0) },
            source: source,
            priority: priority,
            metadata: metadataString
        )

        return try await post("v1/action-items", body: request)
    }
}

// MARK: - Action Item Model (Standalone)

/// Standalone action item stored in Firestore subcollection
/// Different from ActionItem which is embedded in conversation structured data
struct TaskActionItem: Codable, Identifiable {
    let id: String
    let description: String
    let completed: Bool
    let createdAt: Date
    let updatedAt: Date?
    let dueAt: Date?
    let completedAt: Date?
    let conversationId: String?
    /// Source of the task: "screenshot", "transcription:omi", "transcription:desktop", "manual"
    let source: String?
    /// Priority: "high", "medium", "low"
    let priority: String?
    /// JSON metadata string containing extra info like source_app, confidence
    let metadata: String?

    enum CodingKeys: String, CodingKey {
        case id, description, completed, source, priority, metadata
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case dueAt = "due_at"
        case completedAt = "completed_at"
        case conversationId = "conversation_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        completed = try container.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        conversationId = try container.decodeIfPresent(String.self, forKey: .conversationId)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        priority = try container.decodeIfPresent(String.self, forKey: .priority)
        metadata = try container.decodeIfPresent(String.self, forKey: .metadata)
    }

    /// Parse metadata JSON to extract source app name
    var sourceApp: String? {
        guard let metadata = metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["source_app"] as? String
    }

    /// Parse metadata JSON to extract confidence score
    var confidence: Double? {
        guard let metadata = metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["confidence"] as? Double
    }

    /// Display-friendly source label
    var sourceLabel: String {
        guard let source = source else { return "Task" }
        switch source {
        case "screenshot": return "Screen"
        case "transcription:omi": return "OMI"
        case "transcription:desktop": return "Desktop"
        case "transcription:phone": return "Phone"
        case "manual": return "Manual"
        default: return "Task"
        }
    }

    /// System icon name for source
    var sourceIcon: String {
        guard let source = source else { return "list.bullet" }
        switch source {
        case "screenshot": return "camera.fill"
        case "transcription:omi": return "waveform"
        case "transcription:desktop": return "desktopcomputer"
        case "transcription:phone": return "iphone"
        case "manual": return "square.and.pencil"
        default: return "list.bullet"
        }
    }
}

// MARK: - App Models

/// App summary for list views (lightweight)
struct OmiApp: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let image: String
    let category: String
    let author: String
    let capabilities: [String]
    let approved: Bool
    let `private`: Bool
    let installs: Int
    let ratingAvg: Double?
    let ratingCount: Int
    let isPaid: Bool
    let price: Double?
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, image, category, author, capabilities
        case approved
        case `private`
        case installs
        case ratingAvg = "rating_avg"
        case ratingCount = "rating_count"
        case isPaid = "is_paid"
        case price
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "other"
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        `private` = try container.decodeIfPresent(Bool.self, forKey: .private) ?? false
        installs = try container.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        ratingAvg = try container.decodeIfPresent(Double.self, forKey: .ratingAvg)
        ratingCount = try container.decodeIfPresent(Int.self, forKey: .ratingCount) ?? 0
        isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid) ?? false
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    /// Check if app works with chat
    var worksWithChat: Bool {
        capabilities.contains("chat") || capabilities.contains("persona")
    }

    /// Check if app works with memories/conversations
    var worksWithMemories: Bool {
        capabilities.contains("memories")
    }

    /// Check if app has external integration
    var worksExternally: Bool {
        capabilities.contains("external_integration")
    }

    /// Formatted rating string
    var formattedRating: String? {
        guard let rating = ratingAvg else { return nil }
        return String(format: "%.1f", rating)
    }
}

/// Full app details
struct OmiAppDetails: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let image: String
    let category: String
    let author: String
    let email: String?
    let capabilities: [String]
    let uid: String?
    let approved: Bool
    let `private`: Bool
    let status: String
    let chatPrompt: String?
    let memoryPrompt: String?
    let personaPrompt: String?
    let installs: Int
    let ratingAvg: Double?
    let ratingCount: Int
    let isPaid: Bool
    let price: Double?
    let paymentPlan: String?
    let username: String?
    let twitter: String?
    let createdAt: Date?
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, image, category, author, email, capabilities
        case uid, approved
        case `private`
        case status
        case chatPrompt = "chat_prompt"
        case memoryPrompt = "memory_prompt"
        case personaPrompt = "persona_prompt"
        case installs
        case ratingAvg = "rating_avg"
        case ratingCount = "rating_count"
        case isPaid = "is_paid"
        case price
        case paymentPlan = "payment_plan"
        case username, twitter
        case createdAt = "created_at"
        case enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "other"
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        approved = try container.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        `private` = try container.decodeIfPresent(Bool.self, forKey: .private) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "under-review"
        chatPrompt = try container.decodeIfPresent(String.self, forKey: .chatPrompt)
        memoryPrompt = try container.decodeIfPresent(String.self, forKey: .memoryPrompt)
        personaPrompt = try container.decodeIfPresent(String.self, forKey: .personaPrompt)
        installs = try container.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        ratingAvg = try container.decodeIfPresent(Double.self, forKey: .ratingAvg)
        ratingCount = try container.decodeIfPresent(Int.self, forKey: .ratingCount) ?? 0
        isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid) ?? false
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        paymentPlan = try container.decodeIfPresent(String.self, forKey: .paymentPlan)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        twitter = try container.decodeIfPresent(String.self, forKey: .twitter)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

/// App category
struct OmiAppCategory: Codable, Identifiable {
    let id: String
    let title: String
}

/// App capability definition
struct OmiAppCapability: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
}

/// App review
struct OmiAppReview: Codable, Identifiable {
    var id: String { uid }
    let uid: String
    let score: Int
    let review: String
    let response: String?
    let ratedAt: Date
    let editedAt: Date?

    enum CodingKeys: String, CodingKey {
        case uid, score, review, response
        case ratedAt = "rated_at"
        case editedAt = "edited_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        score = try container.decodeIfPresent(Int.self, forKey: .score) ?? 0
        review = try container.decodeIfPresent(String.self, forKey: .review) ?? ""
        response = try container.decodeIfPresent(String.self, forKey: .response)
        ratedAt = try container.decodeIfPresent(Date.self, forKey: .ratedAt) ?? Date()
        editedAt = try container.decodeIfPresent(Date.self, forKey: .editedAt)
    }
}

// MARK: - Apps API

extension APIClient {

    /// Fetches apps from the API
    func getApps(
        capability: String? = nil,
        category: String? = nil,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [OmiApp] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)"
        ]

        if let capability = capability {
            queryItems.append("capability=\(capability)")
        }

        if let category = category {
            queryItems.append("category=\(category)")
        }

        let endpoint = "v1/apps?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Fetches popular apps
    func getPopularApps() async throws -> [OmiApp] {
        return try await get("v1/apps/popular")
    }

    /// Fetches approved public apps
    func getApprovedApps(limit: Int = 50, offset: Int = 0) async throws -> [OmiApp] {
        let endpoint = "v1/approved-apps?limit=\(limit)&offset=\(offset)"
        return try await get(endpoint)
    }

    /// Searches apps with filters
    func searchApps(
        query: String? = nil,
        category: String? = nil,
        capability: String? = nil,
        minRating: Int? = nil,
        installedOnly: Bool = false,
        limit: Int = 50,
        offset: Int = 0
    ) async throws -> [OmiApp] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)"
        ]

        if let query = query, !query.isEmpty {
            queryItems.append("query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)")
        }

        if let category = category {
            queryItems.append("category=\(category)")
        }

        if let capability = capability {
            queryItems.append("capability=\(capability)")
        }

        if let minRating = minRating {
            queryItems.append("rating=\(minRating)")
        }

        if installedOnly {
            queryItems.append("installed_apps=true")
        }

        let endpoint = "v2/apps/search?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Fetches app details by ID
    func getAppDetails(appId: String) async throws -> OmiAppDetails {
        return try await get("v1/apps/\(appId)")
    }

    /// Fetches app reviews
    func getAppReviews(appId: String) async throws -> [OmiAppReview] {
        return try await get("v1/apps/\(appId)/reviews")
    }

    /// Fetches user's enabled apps
    func getEnabledApps() async throws -> [OmiApp] {
        return try await get("v1/apps/enabled")
    }

    /// Enables an app for the current user
    func enableApp(appId: String) async throws {
        struct EnableRequest: Encodable {
            let app_id: String
        }
        struct ToggleResponse: Decodable {
            let success: Bool
            let message: String
        }
        let body = EnableRequest(app_id: appId)
        let _: ToggleResponse = try await post("v1/apps/enable", body: body)
    }

    /// Disables an app for the current user
    func disableApp(appId: String) async throws {
        struct DisableRequest: Encodable {
            let app_id: String
        }
        struct ToggleResponse: Decodable {
            let success: Bool
            let message: String
        }
        let body = DisableRequest(app_id: appId)
        let _: ToggleResponse = try await post("v1/apps/disable", body: body)
    }

    /// Submits a review for an app
    func submitAppReview(appId: String, score: Int, review: String) async throws -> OmiAppReview {
        struct ReviewRequest: Encodable {
            let app_id: String
            let score: Int
            let review: String
        }
        let body = ReviewRequest(app_id: appId, score: score, review: review)
        return try await post("v1/apps/review", body: body)
    }

    /// Fetches all app categories
    func getAppCategories() async throws -> [OmiAppCategory] {
        return try await get("v1/app-categories")
    }

    /// Fetches all app capabilities
    func getAppCapabilities() async throws -> [OmiAppCapability] {
        return try await get("v1/app-capabilities")
    }

    // MARK: - Conversation Reprocessing

    /// Reprocess a conversation with a specific app
    func reprocessConversation(conversationId: String, appId: String) async throws {
        struct ReprocessRequest: Encodable {
            let app_id: String
        }
        struct ReprocessResponse: Decodable {
            let success: Bool
            let message: String
        }
        let body = ReprocessRequest(app_id: appId)
        let _: ReprocessResponse = try await post("v1/conversations/\(conversationId)/reprocess", body: body)
    }
}

// MARK: - User Settings API

extension APIClient {

    /// Fetches daily summary settings
    func getDailySummarySettings() async throws -> DailySummarySettings {
        return try await get("v1/users/daily-summary-settings")
    }

    /// Updates daily summary settings
    func updateDailySummarySettings(enabled: Bool? = nil, hour: Int? = nil) async throws -> DailySummarySettings {
        struct UpdateRequest: Encodable {
            let enabled: Bool?
            let hour: Int?
        }
        let body = UpdateRequest(enabled: enabled, hour: hour)
        return try await patch("v1/users/daily-summary-settings", body: body)
    }

    /// Fetches transcription preferences
    func getTranscriptionPreferences() async throws -> TranscriptionPreferences {
        return try await get("v1/users/transcription-preferences")
    }

    /// Updates transcription preferences
    func updateTranscriptionPreferences(singleLanguageMode: Bool? = nil, vocabulary: [String]? = nil) async throws -> TranscriptionPreferences {
        struct UpdateRequest: Encodable {
            let singleLanguageMode: Bool?
            let vocabulary: [String]?

            enum CodingKeys: String, CodingKey {
                case singleLanguageMode = "single_language_mode"
                case vocabulary
            }
        }
        let body = UpdateRequest(singleLanguageMode: singleLanguageMode, vocabulary: vocabulary)
        return try await patch("v1/users/transcription-preferences", body: body)
    }

    /// Fetches user language preference
    func getUserLanguage() async throws -> UserLanguageResponse {
        return try await get("v1/users/language")
    }

    /// Updates user language preference
    func updateUserLanguage(_ language: String) async throws -> UserLanguageResponse {
        struct UpdateRequest: Encodable {
            let language: String
        }
        let body = UpdateRequest(language: language)
        return try await patch("v1/users/language", body: body)
    }

    /// Fetches recording permission status
    func getRecordingPermission() async throws -> RecordingPermissionResponse {
        return try await get("v1/users/store-recording-permission")
    }

    /// Sets recording permission
    func setRecordingPermission(enabled: Bool) async throws {
        let url = URL(string: baseURL + "v1/users/store-recording-permission?value=\(enabled)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: true)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Fetches private cloud sync setting
    func getPrivateCloudSync() async throws -> PrivateCloudSyncResponse {
        return try await get("v1/users/private-cloud-sync")
    }

    /// Sets private cloud sync
    func setPrivateCloudSync(enabled: Bool) async throws {
        let url = URL(string: baseURL + "v1/users/private-cloud-sync?value=\(enabled)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: true)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Fetches notification settings
    func getNotificationSettings() async throws -> NotificationSettingsResponse {
        return try await get("v1/users/notification-settings")
    }

    /// Updates notification settings
    func updateNotificationSettings(enabled: Bool? = nil, frequency: Int? = nil) async throws -> NotificationSettingsResponse {
        struct UpdateRequest: Encodable {
            let enabled: Bool?
            let frequency: Int?
        }
        let body = UpdateRequest(enabled: enabled, frequency: frequency)
        return try await patch("v1/users/notification-settings", body: body)
    }

    /// Fetches user profile
    func getUserProfile() async throws -> UserProfileResponse {
        return try await get("v1/users/profile")
    }
}

// MARK: - User Settings Models

/// Daily summary notification settings
struct DailySummarySettings: Codable {
    let enabled: Bool
    let hour: Int
}

/// Transcription preferences
struct TranscriptionPreferences: Codable {
    let singleLanguageMode: Bool
    let vocabulary: [String]

    enum CodingKeys: String, CodingKey {
        case singleLanguageMode = "single_language_mode"
        case vocabulary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        singleLanguageMode = try container.decodeIfPresent(Bool.self, forKey: .singleLanguageMode) ?? false
        vocabulary = try container.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
    }
}

/// User language response
struct UserLanguageResponse: Codable {
    let language: String
}

/// Recording permission response
struct RecordingPermissionResponse: Codable {
    let enabled: Bool
}

/// Private cloud sync response
struct PrivateCloudSyncResponse: Codable {
    let enabled: Bool
}

/// Notification settings response
struct NotificationSettingsResponse: Codable {
    let enabled: Bool
    let frequency: Int

    /// Frequency level description
    var frequencyDescription: String {
        switch frequency {
        case 0: return "Off"
        case 1: return "Minimal"
        case 2: return "Low"
        case 3: return "Balanced"
        case 4: return "High"
        case 5: return "Maximum"
        default: return "Unknown"
        }
    }
}

/// User profile response
struct UserProfileResponse: Codable {
    let uid: String
    let email: String?
    let name: String?
    let timeZone: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case uid, email, name
        case timeZone = "time_zone"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(String.self, forKey: .uid)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

// MARK: - Focus Sessions API

extension APIClient {

    /// Fetch focus sessions with optional date filter
    func getFocusSessions(limit: Int = 100, date: String? = nil) async throws -> [FocusSessionResponse] {
        var endpoint = "v1/focus-sessions?limit=\(limit)"
        if let date = date {
            endpoint += "&date=\(date)"
        }
        return try await get(endpoint)
    }

    /// Create a new focus session
    func createFocusSession(_ request: CreateFocusSessionRequest) async throws -> FocusSessionResponse {
        return try await post("v1/focus-sessions", body: request)
    }

    /// Delete a focus session
    func deleteFocusSession(_ id: String) async throws {
        try await delete("v1/focus-sessions/\(id)")
    }

    /// Get focus statistics for a date
    func getFocusStats(date: String? = nil) async throws -> FocusStatsResponse {
        var endpoint = "v1/focus-stats"
        if let date = date {
            endpoint += "?date=\(date)"
        }
        return try await get(endpoint)
    }
}

// MARK: - Advice API

extension APIClient {

    /// Fetches advice history from the backend
    func getAdvice(
        limit: Int = 100,
        offset: Int = 0,
        category: String? = nil,
        includeDismissed: Bool = false
    ) async throws -> [ServerAdvice] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)",
            "include_dismissed=\(includeDismissed)"
        ]

        if let category = category {
            queryItems.append("category=\(category)")
        }

        let endpoint = "v1/advice?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Creates a new advice entry
    func createAdvice(_ request: CreateAdviceRequest) async throws -> ServerAdvice {
        return try await post("v1/advice", body: request)
    }

    /// Updates advice (mark as read/dismissed)
    func updateAdvice(id: String, isRead: Bool? = nil, isDismissed: Bool? = nil) async throws -> ServerAdvice {
        struct UpdateRequest: Encodable {
            let is_read: Bool?
            let is_dismissed: Bool?
        }
        let body = UpdateRequest(is_read: isRead, is_dismissed: isDismissed)
        return try await patch("v1/advice/\(id)", body: body)
    }

    /// Deletes advice permanently
    func deleteAdvice(id: String) async throws {
        try await delete("v1/advice/\(id)")
    }

    /// Marks all advice as read
    func markAllAdviceAsRead() async throws {
        struct StatusResponse: Decodable {
            let status: String
        }
        let _: StatusResponse = try await post("v1/advice/mark-all-read", body: EmptyBody())
    }
}

// MARK: - Advice Models

/// Server advice model matching Rust AdviceDB
struct ServerAdvice: Codable, Identifiable {
    let id: String
    let content: String
    let category: ServerAdviceCategory
    let reasoning: String?
    let sourceApp: String?
    let confidence: Double
    let contextSummary: String?
    let currentActivity: String?
    let createdAt: Date
    let updatedAt: Date?
    let isRead: Bool
    let isDismissed: Bool

    enum CodingKeys: String, CodingKey {
        case id, content, category, reasoning, confidence
        case sourceApp = "source_app"
        case contextSummary = "context_summary"
        case currentActivity = "current_activity"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isRead = "is_read"
        case isDismissed = "is_dismissed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        category = try container.decodeIfPresent(ServerAdviceCategory.self, forKey: .category) ?? .other
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary)
        currentActivity = try container.decodeIfPresent(String.self, forKey: .currentActivity)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
        isDismissed = try container.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
    }
}

/// Server advice category enum matching Rust AdviceCategory
enum ServerAdviceCategory: String, Codable {
    case productivity
    case health
    case communication
    case learning
    case other

    /// Convert to local AdviceCategory
    var toLocal: AdviceCategory {
        switch self {
        case .productivity: return .productivity
        case .health: return .health
        case .communication: return .communication
        case .learning: return .learning
        case .other: return .other
        }
    }
}

/// Request to create new advice
struct CreateAdviceRequest: Encodable {
    let content: String
    let category: String?
    let reasoning: String?
    let source_app: String?
    let confidence: Double?
    let context_summary: String?
    let current_activity: String?

    init(
        content: String,
        category: AdviceCategory? = nil,
        reasoning: String? = nil,
        sourceApp: String? = nil,
        confidence: Double? = nil,
        contextSummary: String? = nil,
        currentActivity: String? = nil
    ) {
        self.content = content
        self.category = category?.rawValue
        self.reasoning = reasoning
        self.source_app = sourceApp
        self.confidence = confidence
        self.context_summary = contextSummary
        self.current_activity = currentActivity
    }
}

/// Empty body for POST requests with no body
struct EmptyBody: Encodable {}

// MARK: - Chat Messages API (Persistence)

extension APIClient {

    /// Save a chat message to the backend
    func saveMessage(
        text: String,
        sender: String,
        appId: String? = nil,
        sessionId: String? = nil
    ) async throws -> SaveMessageResponse {
        struct SaveRequest: Encodable {
            let text: String
            let sender: String
            let app_id: String?
            let session_id: String?
        }
        let body = SaveRequest(text: text, sender: sender, app_id: appId, session_id: sessionId)
        return try await post("v2/messages", body: body)
    }

    /// Fetch chat message history
    func getMessages(
        appId: String? = nil,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> [ChatMessageDB] {
        var queryItems: [String] = [
            "limit=\(limit)",
            "offset=\(offset)"
        ]

        if let appId = appId {
            queryItems.append("app_id=\(appId)")
        }

        let endpoint = "v2/messages?\(queryItems.joined(separator: "&"))"
        return try await get(endpoint)
    }

    /// Clear chat message history
    func deleteMessages(appId: String? = nil) async throws -> MessageDeleteResponse {
        var endpoint = "v2/messages"
        if let appId = appId {
            endpoint += "?app_id=\(appId)"
        }

        let url = URL(string: baseURL + endpoint)!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.allHTTPHeaderFields = try await buildHeaders(requireAuth: true)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return try decoder.decode(MessageDeleteResponse.self, from: data)
    }
}

// MARK: - Chat Message Models

/// Response from saving a message
struct SaveMessageResponse: Codable {
    let id: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
    }
}

/// Persisted chat message from database
struct ChatMessageDB: Codable, Identifiable {
    let id: String
    let text: String
    let createdAt: Date
    let sender: String
    let appId: String?
    let sessionId: String?
    let rating: Int?
    let reported: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, sender, rating, reported
        case createdAt = "created_at"
        case appId = "app_id"
        case sessionId = "session_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? "human"
        appId = try container.decodeIfPresent(String.self, forKey: .appId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        rating = try container.decodeIfPresent(Int.self, forKey: .rating)
        reported = try container.decodeIfPresent(Bool.self, forKey: .reported) ?? false
    }
}

/// Response from deleting messages
struct MessageDeleteResponse: Codable {
    let status: String
    let deletedCount: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case deletedCount = "deleted_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "ok"
        deletedCount = try container.decodeIfPresent(Int.self, forKey: .deletedCount)
    }
}
