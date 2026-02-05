import Foundation
import GRDB

// MARK: - Transcription Session Status

/// Status of a transcription session (upload/sync status)
enum TranscriptionSessionStatus: String, Codable, CaseIterable {
    case recording = "recording"
    case pendingUpload = "pending_upload"
    case uploading = "uploading"
    case completed = "completed"
    case failed = "failed"
}

/// Conversation processing status (from backend)
/// Matches ConversationStatus in APIClient.swift
enum LocalConversationStatus: String, Codable, CaseIterable {
    case inProgress = "in_progress"
    case processing = "processing"
    case merging = "merging"
    case completed = "completed"
    case failed = "failed"
}

// MARK: - Transcription Session Record

/// Database record for transcription recording sessions
/// Stores metadata about a transcription session for crash recovery and retry
/// Also serves as local cache for conversations synced from backend
struct TranscriptionSessionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var startedAt: Date
    var finishedAt: Date?
    var source: String                    // 'desktop', 'omi', etc.
    var language: String
    var timezone: String
    var inputDeviceName: String?
    var status: TranscriptionSessionStatus  // Upload/sync status
    var retryCount: Int
    var lastError: String?
    var backendId: String?                // Server conversation ID
    var backendSynced: Bool
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Structured Data (from ServerConversation.Structured)
    var title: String?
    var overview: String?
    var emoji: String?
    var category: String?
    var actionItemsJson: String?          // JSON-encoded [ActionItem]
    var eventsJson: String?               // JSON-encoded [Event]

    // MARK: - Additional Conversation Data
    var geolocationJson: String?          // JSON-encoded Geolocation
    var photosJson: String?               // JSON-encoded [ConversationPhoto]
    var appsResultsJson: String?          // JSON-encoded [AppResponse]

    // MARK: - Conversation Status & Flags
    var conversationStatus: LocalConversationStatus  // Backend processing status
    var discarded: Bool
    var deleted: Bool
    var isLocked: Bool
    var starred: Bool
    var folderId: String?

    static let databaseTableName = "transcription_sessions"

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        source: String,
        language: String = "en",
        timezone: String = "UTC",
        inputDeviceName: String? = nil,
        status: TranscriptionSessionStatus = .recording,
        retryCount: Int = 0,
        lastError: String? = nil,
        backendId: String? = nil,
        backendSynced: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        // Structured data
        title: String? = nil,
        overview: String? = nil,
        emoji: String? = nil,
        category: String? = nil,
        actionItemsJson: String? = nil,
        eventsJson: String? = nil,
        // Additional data
        geolocationJson: String? = nil,
        photosJson: String? = nil,
        appsResultsJson: String? = nil,
        // Status & flags
        conversationStatus: LocalConversationStatus = .inProgress,
        discarded: Bool = false,
        deleted: Bool = false,
        isLocked: Bool = false,
        starred: Bool = false,
        folderId: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.source = source
        self.language = language
        self.timezone = timezone
        self.inputDeviceName = inputDeviceName
        self.status = status
        self.retryCount = retryCount
        self.lastError = lastError
        self.backendId = backendId
        self.backendSynced = backendSynced
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        // Structured data
        self.title = title
        self.overview = overview
        self.emoji = emoji
        self.category = category
        self.actionItemsJson = actionItemsJson
        self.eventsJson = eventsJson
        // Additional data
        self.geolocationJson = geolocationJson
        self.photosJson = photosJson
        self.appsResultsJson = appsResultsJson
        // Status & flags
        self.conversationStatus = conversationStatus
        self.discarded = discarded
        self.deleted = deleted
        self.isLocked = isLocked
        self.starred = starred
        self.folderId = folderId
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let segments = hasMany(TranscriptionSegmentRecord.self)

    var segments: QueryInterfaceRequest<TranscriptionSegmentRecord> {
        request(for: TranscriptionSessionRecord.segments)
    }

    // MARK: - Computed Properties

    /// Check if this session can be retried (under max retry count)
    var canRetry: Bool {
        retryCount < 5
    }

    /// Calculate backoff delay in seconds based on retry count
    var retryBackoffSeconds: TimeInterval {
        // Exponential backoff: 2^retryCount minutes
        // 0 retries = 1 min, 1 = 2 min, 2 = 4 min, 3 = 8 min, 4 = 16 min
        return pow(2.0, Double(retryCount)) * 60.0
    }

    /// Check if enough time has passed since last update for retry
    func isReadyForRetry(now: Date = Date()) -> Bool {
        guard canRetry else { return false }
        let timeSinceUpdate = now.timeIntervalSince(updatedAt)
        return timeSinceUpdate >= retryBackoffSeconds
    }
}

// MARK: - Transcription Segment Record

/// Database record for individual transcription segments
/// Stores the actual transcribed text with speaker and timing info
/// Also serves as local cache for transcript segments synced from backend
struct TranscriptionSegmentRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var sessionId: Int64
    var speaker: Int                      // Speaker ID (0, 1, 2, etc.)
    var text: String
    var startTime: Double
    var endTime: Double
    var segmentOrder: Int
    var createdAt: Date

    // MARK: - Backend Segment Data (from TranscriptSegment)
    var segmentId: String?                // Backend segment ID (different from local id)
    var speakerLabel: String?             // Speaker label (e.g., "SPEAKER_00")
    var isUser: Bool                      // Whether this segment is from the user
    var personId: String?                 // Associated person ID (if identified)

    static let databaseTableName = "transcription_segments"

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        sessionId: Int64,
        speaker: Int,
        text: String,
        startTime: Double,
        endTime: Double,
        segmentOrder: Int,
        createdAt: Date = Date(),
        // Backend segment data
        segmentId: String? = nil,
        speakerLabel: String? = nil,
        isUser: Bool = false,
        personId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.speaker = speaker
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.segmentOrder = segmentOrder
        self.createdAt = createdAt
        // Backend segment data
        self.segmentId = segmentId
        self.speakerLabel = speakerLabel
        self.isUser = isUser
        self.personId = personId
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Relationships

    static let session = belongsTo(TranscriptionSessionRecord.self)

    var session: QueryInterfaceRequest<TranscriptionSessionRecord> {
        request(for: TranscriptionSegmentRecord.session)
    }
}

// MARK: - Session with Segments

/// Combined session and segments data for upload
struct TranscriptionSessionWithSegments {
    let session: TranscriptionSessionRecord
    let segments: [TranscriptionSegmentRecord]

    /// Check if this session has enough content to upload
    var hasContent: Bool {
        !segments.isEmpty
    }

    /// Total word count across all segments
    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
    }

    /// Total duration in seconds
    var durationSeconds: TimeInterval? {
        guard let start = session.startedAt as Date?,
              let end = session.finishedAt else { return nil }
        return end.timeIntervalSince(start)
    }
}

// MARK: - Transcription Storage Error

/// Errors for TranscriptionStorage operations
enum TranscriptionStorageError: LocalizedError {
    case databaseNotInitialized
    case sessionNotFound
    case invalidState(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Transcription storage database is not initialized"
        case .sessionNotFound:
            return "Transcription session not found"
        case .invalidState(let message):
            return "Invalid session state: \(message)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}
