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
    var tagsJson: String?               // JSON array: ["work", "code"]
    var deletedBy: String?              // "user", "ai_dedup"
    var dueAt: Date?

    // Desktop extraction fields
    var screenshotId: Int64?
    var confidence: Double?
    var sourceApp: String?
    var contextSummary: String?
    var currentActivity: String?
    var metadataJson: String?           // Additional extraction metadata
    var embedding: Data?                // 768 Float32s for vector search

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
        tagsJson: String? = nil,
        deletedBy: String? = nil,
        dueAt: Date? = nil,
        screenshotId: Int64? = nil,
        confidence: Double? = nil,
        sourceApp: String? = nil,
        contextSummary: String? = nil,
        currentActivity: String? = nil,
        metadataJson: String? = nil,
        embedding: Data? = nil,
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
        self.tagsJson = tagsJson
        self.deletedBy = deletedBy
        self.dueAt = dueAt
        self.screenshotId = screenshotId
        self.confidence = confidence
        self.sourceApp = sourceApp
        self.contextSummary = contextSummary
        self.currentActivity = currentActivity
        self.metadataJson = metadataJson
        self.embedding = embedding
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

    // MARK: - Tag Helpers

    /// Get tags as array (decoded from JSON)
    var tags: [String] {
        guard let json = tagsJson,
              let data = json.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }

    /// Set tags from array
    mutating func setTags(_ tags: [String]) {
        if tags.isEmpty {
            tagsJson = nil
        } else if let data = try? JSONEncoder().encode(tags),
                  let json = String(data: data, encoding: .utf8) {
            tagsJson = json
        }
    }

    /// Check if record has a specific tag
    func hasTag(_ tag: String) -> Bool {
        tags.contains(tag)
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
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Create a local record from a TaskActionItem (for caching API responses with full data)
    static func from(_ item: TaskActionItem) -> ActionItemRecord {
        // Build tagsJson from item.tags
        let tagsJson: String?
        let itemTags = item.tags
        if !itemTags.isEmpty,
           let data = try? JSONEncoder().encode(itemTags),
           let json = String(data: data, encoding: .utf8) {
            tagsJson = json
        } else {
            tagsJson = nil
        }

        return ActionItemRecord(
            backendId: item.id,
            backendSynced: true,
            description: item.description,
            completed: item.completed,
            deleted: item.deleted ?? false,
            source: item.source,
            conversationId: item.conversationId,
            priority: item.priority,
            category: item.category,
            tagsJson: tagsJson,
            deletedBy: item.deletedBy,
            dueAt: item.dueAt,
            screenshotId: nil,
            confidence: nil,
            sourceApp: nil,
            contextSummary: nil,
            currentActivity: nil,
            metadataJson: item.metadata,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt ?? item.createdAt
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

    /// Update this record from a TaskActionItem (preserving local id and screenshotId)
    mutating func updateFrom(_ item: TaskActionItem) {
        self.backendId = item.id
        self.backendSynced = true
        self.description = item.description
        self.completed = item.completed
        self.deleted = item.deleted ?? false
        self.deletedBy = item.deletedBy
        self.source = item.source
        self.conversationId = item.conversationId
        self.priority = item.priority
        self.category = item.category
        self.dueAt = item.dueAt
        self.metadataJson = item.metadata
        self.updatedAt = item.updatedAt ?? Date()

        // Sync tags from TaskActionItem
        let itemTags = item.tags
        if !itemTags.isEmpty,
           let data = try? JSONEncoder().encode(itemTags),
           let json = String(data: data, encoding: .utf8) {
            self.tagsJson = json
        }
    }

    /// Convert to ActionItem for UI display (simplified)
    func toActionItem() -> ActionItem {
        return ActionItem(
            description: description,
            completed: completed,
            deleted: deleted
        )
    }

    /// Convert to TaskActionItem for UI display (full data)
    /// Uses backendId if available, otherwise generates a local ID
    func toTaskActionItem() -> TaskActionItem {
        // Use backendId if available, otherwise use local ID prefixed with "local_"
        let taskId = backendId ?? "local_\(id ?? 0)"

        // Ensure metadata contains tags from tagsJson for the TaskActionItem.tags computed property
        var finalMetadata = metadataJson
        let recordTags = tags
        if !recordTags.isEmpty {
            var metaDict = metadata ?? [:]
            metaDict["tags"] = recordTags
            if let data = try? JSONSerialization.data(withJSONObject: metaDict),
               let json = String(data: data, encoding: .utf8) {
                finalMetadata = json
            }
        }

        return TaskActionItem(
            id: taskId,
            description: description,
            completed: completed,
            createdAt: createdAt,
            updatedAt: updatedAt,
            dueAt: dueAt,
            completedAt: nil,  // Not stored locally
            conversationId: conversationId,
            source: source,
            priority: priority,
            metadata: finalMetadata,
            category: category,
            deleted: deleted,
            deletedBy: deletedBy,
            deletedAt: nil,  // Not stored locally
            deletedReason: nil,  // Not stored locally
            keptTaskId: nil  // Not stored locally
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
