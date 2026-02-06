import Foundation
import GRDB

/// Actor-based storage manager for action items/tasks with bidirectional sync
/// Provides local-first caching for fast startup and background sync with backend
actor ActionItemStorage {
    static let shared = ActionItemStorage()

    private var _dbQueue: DatabaseQueue?
    private var isInitialized = false

    private init() {}

    /// Ensure database is initialized before use
    private func ensureInitialized() async throws -> DatabaseQueue {
        if let db = _dbQueue {
            return db
        }

        // Initialize RewindDatabase which creates our tables via migrations
        try await RewindDatabase.shared.initialize()

        guard let db = await RewindDatabase.shared.getDatabaseQueue() else {
            throw ActionItemStorageError.databaseNotInitialized
        }

        _dbQueue = db
        isInitialized = true
        return db
    }

    // MARK: - Local-First Read Operations

    /// Get action items from local cache for instant display
    func getLocalActionItems(
        limit: Int = 50,
        offset: Int = 0,
        completed: Bool? = nil,
        includeDeleted: Bool = false
    ) async throws -> [ActionItem] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord
                .filter(Column("backendSynced") == true)  // Only show synced items

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            let records = try query
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            return records.compactMap { $0.toActionItem() }
        }
    }

    /// Get count of local action items
    func getLocalActionItemsCount(
        completed: Bool? = nil,
        includeDeleted: Bool = false
    ) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord
                .filter(Column("backendSynced") == true)

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            return try query.fetchCount(database)
        }
    }

    /// Get an action item by local ID
    func getActionItem(id: Int64) async throws -> ActionItemRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try ActionItemRecord.fetchOne(database, key: id)
        }
    }

    /// Get an action item by backend ID
    func getActionItemByBackendId(_ backendId: String) async throws -> ActionItemRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try ActionItemRecord
                .filter(Column("backendId") == backendId)
                .fetchOne(database)
        }
    }

    // MARK: - Bidirectional Sync Operations

    /// Sync a single ActionItem to local storage (upsert)
    @discardableResult
    func syncActionItem(_ item: ActionItem, conversationId: String? = nil) async throws -> Int64 {
        let db = try await ensureInitialized()

        return try await db.write { database -> Int64 in
            if var existingRecord = try ActionItemRecord
                .filter(Column("backendId") == item.id)
                .fetchOne(database) {
                existingRecord.updateFrom(item)
                try existingRecord.update(database)
                guard let recordId = existingRecord.id else {
                    throw ActionItemStorageError.syncFailed("Record ID is nil after update")
                }
                return recordId
            } else {
                var newRecord = ActionItemRecord.from(item, conversationId: conversationId)
                try newRecord.insert(database)
                guard let recordId = newRecord.id else {
                    throw ActionItemStorageError.syncFailed("Record ID is nil after insert")
                }
                return recordId
            }
        }
    }

    /// Sync multiple ActionItems to local storage (batch upsert)
    func syncActionItems(_ items: [ActionItem]) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            for item in items {
                if var existingRecord = try ActionItemRecord
                    .filter(Column("backendId") == item.id)
                    .fetchOne(database) {
                    existingRecord.updateFrom(item)
                    try existingRecord.update(database)
                } else {
                    var newRecord = ActionItemRecord.from(item)
                    try newRecord.insert(database)
                }
            }
        }

        log("ActionItemStorage: Synced \(items.count) action items from backend")
    }

    // MARK: - Local Extraction Operations

    /// Insert a locally extracted action item (before backend sync)
    @discardableResult
    func insertLocalActionItem(_ record: ActionItemRecord) async throws -> ActionItemRecord {
        let db = try await ensureInitialized()

        var insertRecord = record
        insertRecord.backendSynced = false

        let inserted = try await db.write { database in
            try insertRecord.inserted(database)
        }

        log("ActionItemStorage: Inserted local action item (id: \(inserted.id ?? -1))")
        return inserted
    }

    /// Mark a local action item as synced with backend ID
    func markSynced(id: Int64, backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try ActionItemRecord.fetchOne(database, key: id) else {
                throw ActionItemStorageError.recordNotFound
            }

            record.backendId = backendId
            record.backendSynced = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("ActionItemStorage: Marked action item \(id) as synced (backendId: \(backendId))")
    }

    /// Get action items that haven't been synced to backend yet
    func getUnsyncedActionItems() async throws -> [ActionItemRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try ActionItemRecord
                .filter(Column("backendSynced") == false)
                .filter(Column("deleted") == false)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    // MARK: - Update Operations

    /// Update action item completion status
    func updateCompletedStatus(id: Int64, completed: Bool) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try ActionItemRecord.fetchOne(database, key: id) else {
                throw ActionItemStorageError.recordNotFound
            }

            record.completed = completed
            record.updatedAt = Date()
            try record.update(database)
        }
    }

    /// Soft delete an action item
    func deleteActionItem(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try ActionItemRecord.fetchOne(database, key: id) else {
                throw ActionItemStorageError.recordNotFound
            }

            record.deleted = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("ActionItemStorage: Soft deleted action item \(id)")
    }

    /// Soft delete an action item by backend ID
    func deleteActionItemByBackendId(_ backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE action_items SET deleted = 1, updatedAt = ? WHERE backendId = ?",
                arguments: [Date(), backendId]
            )
        }

        log("ActionItemStorage: Soft deleted action item with backendId \(backendId)")
    }

    // MARK: - Stats

    /// Get action item storage statistics
    func getStats() async throws -> (total: Int, completed: Int, pending: Int, unsynced: Int) {
        let db = try await ensureInitialized()

        return try await db.read { database in
            let total = try ActionItemRecord
                .filter(Column("deleted") == false)
                .fetchCount(database)

            let completed = try ActionItemRecord
                .filter(Column("deleted") == false)
                .filter(Column("completed") == true)
                .fetchCount(database)

            let pending = try ActionItemRecord
                .filter(Column("deleted") == false)
                .filter(Column("completed") == false)
                .fetchCount(database)

            let unsynced = try ActionItemRecord
                .filter(Column("deleted") == false)
                .filter(Column("backendSynced") == false)
                .fetchCount(database)

            return (total, completed, pending, unsynced)
        }
    }
}
