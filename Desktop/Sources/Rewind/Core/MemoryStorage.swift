import Foundation
import GRDB

/// Actor-based storage manager for memories with bidirectional sync
/// Provides local-first caching for fast startup and background sync with backend
actor MemoryStorage {
    static let shared = MemoryStorage()

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
            throw MemoryStorageError.databaseNotInitialized
        }

        _dbQueue = db
        isInitialized = true
        return db
    }

    // MARK: - Local-First Read Operations

    /// Get memories from local cache for instant display
    /// Supports filtering by category and tags
    func getLocalMemories(
        limit: Int = 50,
        offset: Int = 0,
        category: String? = nil,
        tags: [String]? = nil,
        includeDismissed: Bool = false
    ) async throws -> [ServerMemory] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = MemoryRecord
                .filter(Column("deleted") == false)
                // Show ALL local memories (synced or not) for local-first experience

            if !includeDismissed {
                query = query.filter(Column("isDismissed") == false)
            }

            if let category = category {
                query = query.filter(Column("category") == category)
            }

            // Tag filtering using JSON
            if let tags = tags, !tags.isEmpty {
                for tag in tags {
                    // Use LIKE for JSON array contains check
                    query = query.filter(Column("tagsJson").like("%\"\(tag)\"%"))
                }
            }

            let records = try query
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            return records.compactMap { $0.toServerMemory() }
        }
    }

    /// Get count of local memories
    func getLocalMemoriesCount(
        category: String? = nil,
        tags: [String]? = nil,
        includeDismissed: Bool = false
    ) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = MemoryRecord
                .filter(Column("deleted") == false)
                // Count ALL local memories (synced or not) for local-first experience

            if !includeDismissed {
                query = query.filter(Column("isDismissed") == false)
            }

            if let category = category {
                query = query.filter(Column("category") == category)
            }

            if let tags = tags, !tags.isEmpty {
                for tag in tags {
                    query = query.filter(Column("tagsJson").like("%\"\(tag)\"%"))
                }
            }

            return try query.fetchCount(database)
        }
    }

    /// Get a memory by local ID
    func getMemory(id: Int64) async throws -> MemoryRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try MemoryRecord.fetchOne(database, key: id)
        }
    }

    /// Get a memory by backend ID
    func getMemoryByBackendId(_ backendId: String) async throws -> MemoryRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try MemoryRecord
                .filter(Column("backendId") == backendId)
                .fetchOne(database)
        }
    }

    // MARK: - Bidirectional Sync Operations

    /// Sync a single ServerMemory to local storage (upsert)
    /// Used when fetching from API to cache locally
    @discardableResult
    func syncServerMemory(_ memory: ServerMemory) async throws -> Int64 {
        let db = try await ensureInitialized()

        return try await db.write { database -> Int64 in
            // Check if memory already exists by backendId
            if var existingRecord = try MemoryRecord
                .filter(Column("backendId") == memory.id)
                .fetchOne(database) {
                // Update existing record
                existingRecord.updateFrom(memory)
                try existingRecord.update(database)
                guard let recordId = existingRecord.id else {
                    throw MemoryStorageError.syncFailed("Record ID is nil after update")
                }
                return recordId
            } else {
                // Insert new record
                var newRecord = MemoryRecord.from(memory)
                try newRecord.insert(database)
                guard let recordId = newRecord.id else {
                    throw MemoryStorageError.syncFailed("Record ID is nil after insert")
                }
                return recordId
            }
        }
    }

    /// Sync multiple ServerMemory objects to local storage (batch upsert)
    /// Used for efficient background sync after API fetch
    func syncServerMemories(_ memories: [ServerMemory]) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            for memory in memories {
                if var existingRecord = try MemoryRecord
                    .filter(Column("backendId") == memory.id)
                    .fetchOne(database) {
                    existingRecord.updateFrom(memory)
                    try existingRecord.update(database)
                } else {
                    var newRecord = MemoryRecord.from(memory)
                    try newRecord.insert(database)
                }
            }
        }

        log("MemoryStorage: Synced \(memories.count) memories from backend")
    }

    // MARK: - Local Extraction Operations

    /// Insert a locally extracted memory (before backend sync)
    /// Used by MemoryAssistant and AdviceAssistant
    @discardableResult
    func insertLocalMemory(_ record: MemoryRecord) async throws -> MemoryRecord {
        let db = try await ensureInitialized()

        var insertRecord = record
        insertRecord.backendSynced = false  // Mark as not yet synced

        let inserted = try await db.write { database in
            try insertRecord.inserted(database)
        }

        log("MemoryStorage: Inserted local memory (id: \(inserted.id ?? -1))")
        return inserted
    }

    /// Mark a local memory as synced with backend ID
    func markSynced(id: Int64, backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try MemoryRecord.fetchOne(database, key: id) else {
                throw MemoryStorageError.recordNotFound
            }

            record.backendId = backendId
            record.backendSynced = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("MemoryStorage: Marked memory \(id) as synced (backendId: \(backendId))")
    }

    /// Get memories that haven't been synced to backend yet
    func getUnsyncedMemories() async throws -> [MemoryRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try MemoryRecord
                .filter(Column("backendSynced") == false)
                .filter(Column("deleted") == false)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    // MARK: - Update Operations

    /// Update memory read status
    func updateReadStatus(id: Int64, isRead: Bool) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try MemoryRecord.fetchOne(database, key: id) else {
                throw MemoryStorageError.recordNotFound
            }

            record.isRead = isRead
            record.updatedAt = Date()
            try record.update(database)
        }
    }

    /// Update memory dismissed status
    func updateDismissedStatus(id: Int64, isDismissed: Bool) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try MemoryRecord.fetchOne(database, key: id) else {
                throw MemoryStorageError.recordNotFound
            }

            record.isDismissed = isDismissed
            record.updatedAt = Date()
            try record.update(database)
        }
    }

    /// Mark all memories as read
    func markAllAsRead() async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE memories SET isRead = 1, updatedAt = ? WHERE isRead = 0",
                arguments: [Date()]
            )
        }

        log("MemoryStorage: Marked all memories as read")
    }

    /// Soft delete a memory
    func deleteMemory(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try MemoryRecord.fetchOne(database, key: id) else {
                throw MemoryStorageError.recordNotFound
            }

            record.deleted = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("MemoryStorage: Soft deleted memory \(id)")
    }

    /// Soft delete a memory by backend ID
    func deleteMemoryByBackendId(_ backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "UPDATE memories SET deleted = 1, updatedAt = ? WHERE backendId = ?",
                arguments: [Date(), backendId]
            )
        }

        log("MemoryStorage: Soft deleted memory with backendId \(backendId)")
    }

    // MARK: - Stats

    /// Get memory storage statistics
    func getStats() async throws -> (total: Int, synced: Int, unsynced: Int, unread: Int) {
        let db = try await ensureInitialized()

        return try await db.read { database in
            let total = try MemoryRecord
                .filter(Column("deleted") == false)
                .fetchCount(database)

            let synced = try MemoryRecord
                .filter(Column("deleted") == false)
                .filter(Column("backendSynced") == true)
                .fetchCount(database)

            let unsynced = try MemoryRecord
                .filter(Column("deleted") == false)
                .filter(Column("backendSynced") == false)
                .fetchCount(database)

            let unread = try MemoryRecord
                .filter(Column("deleted") == false)
                .filter(Column("isRead") == false)
                .filter(Column("isDismissed") == false)
                .fetchCount(database)

            return (total, synced, unsynced, unread)
        }
    }

    // MARK: - Cleanup

    /// Permanently delete old dismissed memories
    func cleanupOldDismissedMemories(olderThan date: Date) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.write { database in
            let count = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM memories WHERE isDismissed = 1 AND updatedAt < ?",
                arguments: [date]
            ) ?? 0

            try database.execute(
                sql: "DELETE FROM memories WHERE isDismissed = 1 AND updatedAt < ?",
                arguments: [date]
            )

            return count
        }
    }
}
