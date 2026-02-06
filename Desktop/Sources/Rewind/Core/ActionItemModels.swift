import Foundation
import GRDB

// MARK: - Action Item Record

/// Database record for action items/tasks with bidirectional sync support
/// Stores tasks from both local extraction (screenshots) and backend API
struct ActionItemRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?

    // Backend sync fields
    var backendId: String?              // Server action item ID
    var backendSynced: Bool

    // Core ActionItem fields
    var description: String
    var completed: Bool
    var deleted: Bool
    var source: String?                 // screenshot, conversation, omi
    var conversationId: String?
    var priority: String?               // high, medium, low
    var category: String?
    var dueAt: Date?

    // Desktop extraction fields
    var screenshotId: Int64?
    var confidence: Double?
    var sourceApp: String?
    var contextSummary: String?
    var currentActivity: String?
    var metadataJson: String?           // Additional extraction metadata

    // Timestamps
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "action_items"

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        backendId: String? = nil,
        backendSynced: Bool = false,
        description: String,
        completed: Bool = false,
        deleted: Bool = false,
        source: String? = nil,
        conversationId: String? = nil,
        priority: String? = nil,
        category: String? = nil,
        dueAt: Date? = nil,
        screenshotId: Int64? = nil,
        confidence: Double? = nil,
        sourceApp: String? = nil,
        contextSummary: String? = nil,
        currentActivity: String? = nil,
        metadataJson: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.backendId = backendId
        self.backendSynced = backendSynced
        self.description = description
        self.completed = completed
        self.deleted = deleted
        self.source = source
        self.conversationId = conversationId
        self.priority = priority
        self.category = category
        self.dueAt = dueAt
        self.screenshotId = screenshotId
        self.confidence = confidence
        self.sourceApp = sourceApp
        self.contextSummary = contextSummary
        self.currentActivity = currentActivity
        self.metadataJson = metadataJson
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Metadata Helpers

    /// Get metadata as dictionary
    var metadata: [String: Any]? {
        guard let json = metadataJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    /// Set metadata from dictionary
    mutating func setMetadata(_ metadata: [String: Any]?) {
        guard let metadata = metadata,
              let data = try? JSONSerialization.data(withJSONObject: metadata),
              let json = String(data: data, encoding: .utf8)
        else {
            metadataJson = nil
            return
        }
        metadataJson = json
    }

    // MARK: - Relationships

    static let screenshot = belongsTo(Screenshot.self)

    var screenshot: QueryInterfaceRequest<Screenshot> {
        request(for: ActionItemRecord.screenshot)
    }
}

// MARK: - ActionItem Conversion

extension ActionItemRecord {
    /// Create a local record from an ActionItem (for caching API responses)
    static func from(_ item: ActionItem, conversationId: String? = nil) -> ActionItemRecord {
        return ActionItemRecord(
            backendId: item.id,
            backendSynced: true,
            description: item.description,
            completed: item.completed,
            deleted: item.deleted,
            source: nil,  // Not available from ActionItem
            conversationId: conversationId,
            priority: nil,  // Not in current ActionItem struct
            category: nil,  // Not in current ActionItem struct
            dueAt: nil,  // Not in current ActionItem struct
            screenshotId: nil,
            confidence: nil,
            sourceApp: nil,
            contextSummary: nil,
            currentActivity: nil,
            metadataJson: nil,
            createdAt: item.createdAt,
            updatedAt: Date()
        )
    }

    /// Update this record from an ActionItem (preserving local id and screenshotId)
    mutating func updateFrom(_ item: ActionItem) {
        self.backendId = item.id
        self.backendSynced = true
        self.description = item.description
        self.completed = item.completed
        self.deleted = item.deleted
        self.updatedAt = Date()
    }

    /// Convert to ActionItem for UI display
    func toActionItem() -> ActionItem? {
        guard let backendId = backendId else { return nil }

        return ActionItem(
            id: backendId,
            description: description,
            completed: completed,
            deleted: deleted,
            createdAt: createdAt
        )
    }
}

// MARK: - Action Item Storage Error

enum ActionItemStorageError: LocalizedError {
    case databaseNotInitialized
    case recordNotFound
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Action item storage database is not initialized"
        case .recordNotFound:
            return "Action item record not found"
        case .syncFailed(let message):
            return "Sync failed: \(message)"
        }
    }
}
