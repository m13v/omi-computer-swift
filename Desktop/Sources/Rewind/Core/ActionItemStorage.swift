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
    /// Returns TaskActionItem for full UI compatibility
    /// Supports filtering by category, source, and priority for efficient SQLite queries
    func getLocalActionItems(
        limit: Int = 50,
        offset: Int = 0,
        completed: Bool? = nil,
        includeDeleted: Bool = false,
        startDate: Date? = nil,
        category: String? = nil,
        source: String? = nil,
        priority: String? = nil
    ) async throws -> [TaskActionItem] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord.all()
            // Show ALL local items (synced or not) for local-first experience

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            // Filter by start date (for 7-day filter)
            if let startDate = startDate {
                query = query.filter(Column("createdAt") >= startDate)
            }

            // Filter by category
            if let category = category {
                query = query.filter(Column("category") == category)
            }

            // Filter by source
            if let source = source {
                query = query.filter(Column("source") == source)
            }

            // Filter by priority
            if let priority = priority {
                query = query.filter(Column("priority") == priority)
            }

            let records = try query
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            return records.map { $0.toTaskActionItem() }
        }
    }

    /// Get count of local action items
    func getLocalActionItemsCount(
        completed: Bool? = nil,
        includeDeleted: Bool = false,
        startDate: Date? = nil
    ) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord.all()
            // Count ALL local items (synced or not) for local-first experience

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            if let startDate = startDate {
                query = query.filter(Column("createdAt") >= startDate)
            }

            return try query.fetchCount(database)
        }
    }

    /// Get action items with multiple filter values (OR within groups, AND between groups)
    /// Used when user selects multiple filters in the UI
    func getFilteredActionItems(
        limit: Int = 200,
        offset: Int = 0,
        completedStates: [Bool]? = nil,  // e.g., [true, false] for both done and todo
        includeDeleted: Bool = false,
        categories: [String]? = nil,     // OR logic: matches any category
        sources: [String]? = nil,        // OR logic: matches any source
        priorities: [String]? = nil      // OR logic: matches any priority
    ) async throws -> [TaskActionItem] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord.all()

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            // Filter by completed states (OR logic)
            if let states = completedStates, !states.isEmpty {
                if states.count == 1 {
                    query = query.filter(Column("completed") == states[0])
                }
                // If both true and false, no filter needed (show all)
            }

            // Filter by categories (OR logic)
            if let categories = categories, !categories.isEmpty {
                query = query.filter(categories.contains(Column("category")))
            }

            // Filter by sources (OR logic)
            if let sources = sources, !sources.isEmpty {
                query = query.filter(sources.contains(Column("source")))
            }

            // Filter by priorities (OR logic)
            if let priorities = priorities, !priorities.isEmpty {
                query = query.filter(priorities.contains(Column("priority")))
            }

            let records = try query
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            return records.map { $0.toTaskActionItem() }
        }
    }

    /// Search action items by description text (case-insensitive)
    /// Queries SQLite directly for efficient full-database search
    func searchLocalActionItems(
        query searchText: String,
        limit: Int = 100,
        offset: Int = 0,
        completed: Bool? = nil,
        includeDeleted: Bool = false,
        category: String? = nil,
        source: String? = nil,
        priority: String? = nil
    ) async throws -> [TaskActionItem] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord.all()

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            // Search in description (case-insensitive)
            if !searchText.isEmpty {
                query = query.filter(Column("description").like("%\(searchText)%"))
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            if let category = category {
                query = query.filter(Column("category") == category)
            }

            if let source = source {
                query = query.filter(Column("source") == source)
            }

            if let priority = priority {
                query = query.filter(Column("priority") == priority)
            }

            let records = try query
                .order(Column("createdAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(database)

            return records.map { $0.toTaskActionItem() }
        }
    }

    /// Get count of action items matching search and filters
    func searchLocalActionItemsCount(
        query searchText: String,
        completed: Bool? = nil,
        includeDeleted: Bool = false,
        category: String? = nil,
        source: String? = nil,
        priority: String? = nil
    ) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            var query = ActionItemRecord.all()

            if !includeDeleted {
                query = query.filter(Column("deleted") == false)
            }

            if !searchText.isEmpty {
                query = query.filter(Column("description").like("%\(searchText)%"))
            }

            if let completed = completed {
                query = query.filter(Column("completed") == completed)
            }

            if let category = category {
                query = query.filter(Column("category") == category)
            }

            if let source = source {
                query = query.filter(Column("source") == source)
            }

            if let priority = priority {
                query = query.filter(Column("priority") == priority)
            }

            return try query.fetchCount(database)
        }
    }

    /// Get count of action items by filter criteria (for filter tag counts)
    func getFilterCounts() async throws -> (
        todo: Int,
        done: Int,
        deleted: Int,
        categories: [String: Int],
        sources: [String: Int],
        priorities: [String: Int]
    ) {
        let db = try await ensureInitialized()

        return try await db.read { database in
            let todo = try ActionItemRecord
                .filter(Column("deleted") == false)
                .filter(Column("completed") == false)
                .fetchCount(database)

            let done = try ActionItemRecord
                .filter(Column("deleted") == false)
                .filter(Column("completed") == true)
                .fetchCount(database)

            let deleted = try ActionItemRecord
                .filter(Column("deleted") == true)
                .fetchCount(database)

            // Category counts
            var categories: [String: Int] = [:]
            let categoryRows = try Row.fetchAll(database, sql: """
                SELECT category, COUNT(*) as count FROM action_items
                WHERE deleted = 0 AND category IS NOT NULL
                GROUP BY category
            """)
            for row in categoryRows {
                if let cat: String = row["category"], let count: Int = row["count"] {
                    categories[cat] = count
                }
            }

            // Source counts
            var sources: [String: Int] = [:]
            let sourceRows = try Row.fetchAll(database, sql: """
                SELECT source, COUNT(*) as count FROM action_items
                WHERE deleted = 0 AND source IS NOT NULL
                GROUP BY source
            """)
            for row in sourceRows {
                if let src: String = row["source"], let count: Int = row["count"] {
                    sources[src] = count
                }
            }

            // Priority counts
            var priorities: [String: Int] = [:]
            let priorityRows = try Row.fetchAll(database, sql: """
                SELECT priority, COUNT(*) as count FROM action_items
                WHERE deleted = 0 AND priority IS NOT NULL
                GROUP BY priority
            """)
            for row in priorityRows {
                if let pri: String = row["priority"], let count: Int = row["count"] {
                    priorities[pri] = count
                }
            }

            return (todo, done, deleted, categories, sources, priorities)
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
                let newRecord = try ActionItemRecord.from(item, conversationId: conversationId).inserted(database)
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
                    let newRecord = ActionItemRecord.from(item)
                    try newRecord.insert(database)
                }
            }
        }

        log("ActionItemStorage: Synced \(items.count) action items from backend")
    }

    /// Sync multiple TaskActionItems to local storage (batch upsert with full data)
    func syncTaskActionItems(_ items: [TaskActionItem]) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            for item in items {
                if var existingRecord = try ActionItemRecord
                    .filter(Column("backendId") == item.id)
                    .fetchOne(database) {
                    existingRecord.updateFrom(item)
                    try existingRecord.update(database)
                } else {
                    let newRecord = ActionItemRecord.from(item)
                    try newRecord.insert(database)
                }
            }
        }

        log("ActionItemStorage: Synced \(items.count) task action items from backend")
    }

    // MARK: - Local Extraction Operations

    /// Insert a locally extracted action item (before backend sync)
    @discardableResult
    func insertLocalActionItem(_ record: ActionItemRecord) async throws -> ActionItemRecord {
        let db = try await ensureInitialized()

        var insertRecord = record
        insertRecord.backendSynced = false
        let recordToInsert = insertRecord

        let inserted = try await db.write { database in
            try recordToInsert.inserted(database)
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
