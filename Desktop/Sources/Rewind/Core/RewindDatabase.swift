import Foundation
import GRDB

/// Actor-based database manager for Rewind screenshots
actor RewindDatabase {
    static let shared = RewindDatabase()

    private var dbQueue: DatabaseQueue?

    // MARK: - Initialization

    private init() {}

    /// Get the database queue for other storage actors
    func getDatabaseQueue() -> DatabaseQueue? {
        return dbQueue
    }

    /// Initialize the database with migrations
    func initialize() async throws {
        guard dbQueue == nil else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omiDir = appSupport.appendingPathComponent("Omi", isDirectory: true)

        // Create directory if needed
        try FileManager.default.createDirectory(at: omiDir, withIntermediateDirectories: true)

        let dbPath = omiDir.appendingPathComponent("omi.db").path
        log("RewindDatabase: Opening database at \(dbPath)")

        var config = Configuration()
        config.prepareDatabase { db in
            // Enable foreign keys
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let queue = try DatabaseQueue(path: dbPath, configuration: config)
        dbQueue = queue

        try migrate(queue)
        log("RewindDatabase: Initialized successfully")
    }

    // MARK: - Migrations

    private func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        // Migration 1: Create screenshots table
        migrator.registerMigration("createScreenshots") { db in
            try db.create(table: "screenshots") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("timestamp", .datetime).notNull()
                t.column("appName", .text).notNull()
                t.column("windowTitle", .text)
                t.column("imagePath", .text).notNull()
                t.column("ocrText", .text)
                t.column("isIndexed", .boolean).notNull().defaults(to: false)
                t.column("focusStatus", .text)
                t.column("extractedTasksJson", .text)
                t.column("adviceJson", .text)
            }

            // Create indexes
            try db.create(index: "idx_screenshots_timestamp", on: "screenshots", columns: ["timestamp"])
            try db.create(index: "idx_screenshots_appName", on: "screenshots", columns: ["appName"])
            try db.create(index: "idx_screenshots_isIndexed", on: "screenshots", columns: ["isIndexed"])
        }

        // Migration 2: Create FTS5 virtual table for full-text search
        migrator.registerMigration("createScreenshotsFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE screenshots_fts USING fts5(
                    ocrText,
                    windowTitle,
                    content='screenshots',
                    content_rowid='id'
                )
                """)

            // Create triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER screenshots_ai AFTER INSERT ON screenshots BEGIN
                    INSERT INTO screenshots_fts(rowid, ocrText, windowTitle)
                    VALUES (new.id, new.ocrText, new.windowTitle);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER screenshots_ad AFTER DELETE ON screenshots BEGIN
                    INSERT INTO screenshots_fts(screenshots_fts, rowid, ocrText, windowTitle)
                    VALUES ('delete', old.id, old.ocrText, old.windowTitle);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER screenshots_au AFTER UPDATE ON screenshots BEGIN
                    INSERT INTO screenshots_fts(screenshots_fts, rowid, ocrText, windowTitle)
                    VALUES ('delete', old.id, old.ocrText, old.windowTitle);
                    INSERT INTO screenshots_fts(rowid, ocrText, windowTitle)
                    VALUES (new.id, new.ocrText, new.windowTitle);
                END
                """)
        }

        // Migration 3: Create proactive_extractions table for memories, tasks, and advice
        migrator.registerMigration("createProactiveExtractions") { db in
            try db.create(table: "proactive_extractions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("screenshotId", .integer)
                    .references("screenshots", onDelete: .cascade)
                t.column("type", .text).notNull() // memory, task, advice
                t.column("content", .text).notNull()
                t.column("category", .text) // memory: system/interesting, advice: productivity/health/etc
                t.column("confidence", .double)
                t.column("reasoning", .text)
                t.column("sourceApp", .text).notNull()
                t.column("contextSummary", .text)
                t.column("priority", .text) // For tasks: high/medium/low
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isDismissed", .boolean).notNull().defaults(to: false)
                t.column("backendId", .text) // Server ID after sync
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Indexes for common queries
            try db.create(index: "idx_extractions_type", on: "proactive_extractions", columns: ["type"])
            try db.create(index: "idx_extractions_screenshot", on: "proactive_extractions", columns: ["screenshotId"])
            try db.create(index: "idx_extractions_synced", on: "proactive_extractions", columns: ["backendSynced"])
            try db.create(index: "idx_extractions_created", on: "proactive_extractions", columns: ["createdAt"])
            try db.create(index: "idx_extractions_type_created", on: "proactive_extractions", columns: ["type", "createdAt"])
        }

        // Migration 4: Create focus_sessions table for focus tracking
        migrator.registerMigration("createFocusSessions") { db in
            try db.create(table: "focus_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("screenshotId", .integer)
                    .references("screenshots", onDelete: .cascade)
                t.column("status", .text).notNull() // focused, distracted
                t.column("appOrSite", .text).notNull()
                t.column("description", .text).notNull()
                t.column("message", .text)
                t.column("durationSeconds", .integer)
                t.column("backendId", .text)
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }

            // Indexes for time-based aggregation queries
            try db.create(index: "idx_focus_created", on: "focus_sessions", columns: ["createdAt"])
            try db.create(index: "idx_focus_status", on: "focus_sessions", columns: ["status"])
            try db.create(index: "idx_focus_screenshot", on: "focus_sessions", columns: ["screenshotId"])
            try db.create(index: "idx_focus_synced", on: "focus_sessions", columns: ["backendSynced"])
        }

        // Migration 5: Add ocrDataJson column for bounding boxes
        migrator.registerMigration("addOcrDataJson") { db in
            try db.alter(table: "screenshots") { t in
                t.add(column: "ocrDataJson", .text)
            }
        }

        // Migration 6: Create FTS for proactive_extractions content search
        migrator.registerMigration("createExtractionsFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE proactive_extractions_fts USING fts5(
                    content,
                    reasoning,
                    contextSummary,
                    content='proactive_extractions',
                    content_rowid='id'
                )
                """)

            // Triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER extractions_ai AFTER INSERT ON proactive_extractions BEGIN
                    INSERT INTO proactive_extractions_fts(rowid, content, reasoning, contextSummary)
                    VALUES (new.id, new.content, new.reasoning, new.contextSummary);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER extractions_ad AFTER DELETE ON proactive_extractions BEGIN
                    INSERT INTO proactive_extractions_fts(proactive_extractions_fts, rowid, content, reasoning, contextSummary)
                    VALUES ('delete', old.id, old.content, old.reasoning, old.contextSummary);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER extractions_au AFTER UPDATE ON proactive_extractions BEGIN
                    INSERT INTO proactive_extractions_fts(proactive_extractions_fts, rowid, content, reasoning, contextSummary)
                    VALUES ('delete', old.id, old.content, old.reasoning, old.contextSummary);
                    INSERT INTO proactive_extractions_fts(rowid, content, reasoning, contextSummary)
                    VALUES (new.id, new.content, new.reasoning, new.contextSummary);
                END
                """)
        }

        // Migration 7: Add video chunk storage columns
        migrator.registerMigration("addVideoChunkColumns") { db in
            try db.alter(table: "screenshots") { t in
                t.add(column: "videoChunkPath", .text)
                t.add(column: "frameOffset", .integer)
            }
            // Make imagePath nullable for new video-based screenshots
            // Note: SQLite doesn't support ALTER COLUMN, but new rows can have NULL imagePath

            // Index for efficient chunk-based queries
            try db.create(index: "idx_screenshots_videoChunkPath",
                          on: "screenshots", columns: ["videoChunkPath"])
        }

        // Migration 8: Rebuild FTS to include appName for better search
        migrator.registerMigration("rebuildFTSWithAppName") { db in
            // Drop old FTS table and triggers
            try db.execute(sql: "DROP TRIGGER IF EXISTS screenshots_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS screenshots_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS screenshots_au")
            try db.execute(sql: "DROP TABLE IF EXISTS screenshots_fts")

            // Create new FTS table with appName included
            try db.execute(sql: """
                CREATE VIRTUAL TABLE screenshots_fts USING fts5(
                    ocrText,
                    windowTitle,
                    appName,
                    content='screenshots',
                    content_rowid='id',
                    tokenize='unicode61'
                )
                """)

            // Recreate triggers to keep FTS in sync
            try db.execute(sql: """
                CREATE TRIGGER screenshots_ai AFTER INSERT ON screenshots BEGIN
                    INSERT INTO screenshots_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.ocrText, new.windowTitle, new.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER screenshots_ad AFTER DELETE ON screenshots BEGIN
                    INSERT INTO screenshots_fts(screenshots_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.ocrText, old.windowTitle, old.appName);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER screenshots_au AFTER UPDATE ON screenshots BEGIN
                    INSERT INTO screenshots_fts(screenshots_fts, rowid, ocrText, windowTitle, appName)
                    VALUES ('delete', old.id, old.ocrText, old.windowTitle, old.appName);
                    INSERT INTO screenshots_fts(rowid, ocrText, windowTitle, appName)
                    VALUES (new.id, new.ocrText, new.windowTitle, new.appName);
                END
                """)

            // Repopulate FTS with existing data
            try db.execute(sql: """
                INSERT INTO screenshots_fts(rowid, ocrText, windowTitle, appName)
                SELECT id, ocrText, windowTitle, appName FROM screenshots
                """)
        }

        try migrator.migrate(queue)
    }

    // MARK: - CRUD Operations

    /// Insert a new screenshot record
    @discardableResult
    func insertScreenshot(_ screenshot: Screenshot) throws -> Screenshot {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.write { db -> Screenshot in
            let record = screenshot
            try record.insert(db)
            return record
        }
    }

    /// Update OCR text for a screenshot (legacy - without bounding boxes)
    func updateOCRText(id: Int64, ocrText: String) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET ocrText = ?, isIndexed = 1 WHERE id = ?",
                arguments: [ocrText, id]
            )
        }
    }

    /// Update OCR result with bounding boxes for a screenshot
    func updateOCRResult(id: Int64, ocrResult: OCRResult) throws {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        let ocrDataJson: String?
        do {
            let data = try JSONEncoder().encode(ocrResult)
            ocrDataJson = String(data: data, encoding: .utf8)
        } catch {
            ocrDataJson = nil
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE screenshots SET ocrText = ?, ocrDataJson = ?, isIndexed = 1 WHERE id = ?",
                arguments: [ocrResult.fullText, ocrDataJson, id]
            )
        }
    }

    /// Get screenshots pending OCR processing
    func getPendingOCRScreenshots(limit: Int = 10) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .filter(Column("isIndexed") == false)
                .order(Column("timestamp").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get screenshot by ID
    func getScreenshot(id: Int64) throws -> Screenshot? {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot.fetchOne(db, key: id)
        }
    }

    /// Get screenshots for a date range
    func getScreenshots(from startDate: Date, to endDate: Date, limit: Int = 100) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .filter(Column("timestamp") >= startDate && Column("timestamp") <= endDate)
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get recent screenshots
    func getRecentScreenshots(limit: Int = 50) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Screenshot
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Get all unique app names
    func getUniqueAppNames() throws -> [String] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT DISTINCT appName FROM screenshots ORDER BY appName")
        }
    }

    // MARK: - Search

    /// Expand a search query by splitting compound words (camelCase, numbers)
    /// e.g., "ActivityPerformance" -> "(ActivityPerformance* OR Activity* OR Performance*)"
    private func expandSearchQuery(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Split query into words
        let words = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        let expandedWords = words.map { word -> String in
            var parts: [String] = [word]

            // Split camelCase: "ActivityPerformance" -> ["Activity", "Performance"]
            let camelCaseParts = splitCamelCase(word)
            if camelCaseParts.count > 1 {
                parts.append(contentsOf: camelCaseParts)
            }

            // Split on number boundaries: "test123" -> ["test", "123"]
            let numberParts = splitOnNumbers(word)
            if numberParts.count > 1 {
                parts.append(contentsOf: numberParts)
            }

            // Remove duplicates and create OR query with prefix matching
            let uniqueParts = Array(Set(parts)).filter { $0.count >= 2 }
            if uniqueParts.count == 1 {
                return "\(uniqueParts[0])*"
            } else {
                let prefixParts = uniqueParts.map { "\($0)*" }
                return "(\(prefixParts.joined(separator: " OR ")))"
            }
        }

        return expandedWords.joined(separator: " ")
    }

    /// Split camelCase string into parts
    private func splitCamelCase(_ string: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""

        for char in string {
            if char.isUppercase && !currentPart.isEmpty {
                parts.append(currentPart)
                currentPart = String(char)
            } else {
                currentPart.append(char)
            }
        }

        if !currentPart.isEmpty {
            parts.append(currentPart)
        }

        return parts.filter { $0.count >= 2 }
    }

    /// Split string on number boundaries
    private func splitOnNumbers(_ string: String) -> [String] {
        var parts: [String] = []
        var currentPart = ""
        var wasDigit = false

        for char in string {
            let isDigit = char.isNumber
            if !currentPart.isEmpty && isDigit != wasDigit {
                parts.append(currentPart)
                currentPart = String(char)
            } else {
                currentPart.append(char)
            }
            wasDigit = isDigit
        }

        if !currentPart.isEmpty {
            parts.append(currentPart)
        }

        return parts.filter { $0.count >= 2 }
    }

    /// Full-text search on OCR text, window titles, and app names
    /// - Parameters:
    ///   - query: Search query (supports compound word expansion)
    ///   - appFilter: Optional app name filter (exact match)
    ///   - startDate: Optional start date for time range
    ///   - endDate: Optional end date for time range
    ///   - limit: Maximum results to return
    func search(
        query: String,
        appFilter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 100
    ) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Expand the query for better matching
        let expandedQuery = expandSearchQuery(query)
        guard !expandedQuery.isEmpty else {
            return []
        }

        return try dbQueue.read { db in
            var sql = """
                SELECT screenshots.* FROM screenshots
                JOIN screenshots_fts ON screenshots.id = screenshots_fts.rowid
                WHERE screenshots_fts MATCH ?
                """
            var arguments: [DatabaseValueConvertible] = [expandedQuery]

            // App filter (exact match, separate from FTS)
            if let app = appFilter {
                sql += " AND screenshots.appName = ?"
                arguments.append(app)
            }

            // Time range filtering
            if let start = startDate {
                sql += " AND screenshots.timestamp >= ?"
                arguments.append(start)
            }

            if let end = endDate {
                sql += " AND screenshots.timestamp <= ?"
                arguments.append(end)
            }

            // Order by relevance (BM25) then by timestamp
            sql += " ORDER BY bm25(screenshots_fts) ASC, screenshots.timestamp DESC LIMIT ?"
            arguments.append(limit)

            return try Screenshot.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Delete Result Types

    /// Result of bulk screenshot deletion (for cleanup)
    struct DeleteResult {
        let imagePaths: [String]           // Legacy JPEG paths to delete
        let orphanedVideoChunks: [String]  // Video chunks with all frames deleted
    }

    /// Result of single screenshot deletion
    struct SingleDeleteResult {
        let imagePath: String?
        let videoChunkPath: String?
        let isLastFrameInChunk: Bool
    }

    // MARK: - Cleanup

    /// Delete screenshots older than the specified date
    func deleteScreenshotsOlderThan(_ date: Date) throws -> DeleteResult {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // First get the image paths to delete (legacy JPEGs)
        let imagePaths = try dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM screenshots WHERE timestamp < ? AND imagePath IS NOT NULL",
                arguments: [date]
            )
        }

        // Get video chunk paths that will have frames deleted
        let videoChunksToCheck = try dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT DISTINCT videoChunkPath FROM screenshots WHERE timestamp < ? AND videoChunkPath IS NOT NULL",
                arguments: [date]
            )
        }

        // Delete the records
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE timestamp < ?",
                arguments: [date]
            )
        }

        // Check which video chunks are now orphaned (no remaining frames)
        let orphanedChunks = try dbQueue.read { db -> [String] in
            var orphaned: [String] = []
            for chunkPath in videoChunksToCheck {
                let remainingCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                    arguments: [chunkPath]
                ) ?? 0
                if remainingCount == 0 {
                    orphaned.append(chunkPath)
                }
            }
            return orphaned
        }

        return DeleteResult(imagePaths: imagePaths, orphanedVideoChunks: orphanedChunks)
    }

    /// Delete a specific screenshot
    func deleteScreenshot(id: Int64) throws -> SingleDeleteResult? {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Get the storage info first
        let storageInfo = try dbQueue.read { db -> (imagePath: String?, videoChunkPath: String?)? in
            try Row.fetchOne(
                db,
                sql: "SELECT imagePath, videoChunkPath FROM screenshots WHERE id = ?",
                arguments: [id]
            ).map { row in
                (imagePath: row["imagePath"] as String?, videoChunkPath: row["videoChunkPath"] as String?)
            }
        }

        guard let info = storageInfo else {
            return nil
        }

        // Check if this is the last frame in the video chunk
        var isLastFrame = false
        if let videoChunkPath = info.videoChunkPath {
            let frameCount = try dbQueue.read { db -> Int in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                    arguments: [videoChunkPath]
                ) ?? 0
            }
            isLastFrame = frameCount == 1
        }

        // Delete the record
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE id = ?",
                arguments: [id]
            )
        }

        return SingleDeleteResult(
            imagePath: info.imagePath,
            videoChunkPath: info.videoChunkPath,
            isLastFrameInChunk: isLastFrame
        )
    }

    /// Get total screenshot count
    func getScreenshotCount() throws -> Int {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots") ?? 0
        }
    }

    /// Get database statistics
    func getStats() throws -> (total: Int, indexed: Int, oldestDate: Date?, newestDate: Date?) {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            let totalCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots") ?? 0
            let indexedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots WHERE isIndexed = 1") ?? 0
            let oldestDate = try Date.fetchOne(db, sql: "SELECT MIN(timestamp) FROM screenshots")
            let newestDate = try Date.fetchOne(db, sql: "SELECT MAX(timestamp) FROM screenshots")

            return (totalCount, indexedCount, oldestDate, newestDate)
        }
    }
}
