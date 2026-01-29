import Foundation
import GRDB

/// Actor-based database manager for Rewind screenshots
actor RewindDatabase {
    static let shared = RewindDatabase()

    private var dbQueue: DatabaseQueue?

    // MARK: - Initialization

    private init() {}

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
            var record = screenshot
            try record.insert(db)
            return record
        }
    }

    /// Update OCR text for a screenshot
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

    /// Full-text search on OCR text and window titles
    func search(query: String, appFilter: String? = nil, limit: Int = 100) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            var sql = """
                SELECT screenshots.* FROM screenshots
                JOIN screenshots_fts ON screenshots.id = screenshots_fts.rowid
                WHERE screenshots_fts MATCH ?
                """
            var arguments: [DatabaseValueConvertible] = [query + "*"]

            if let app = appFilter {
                sql += " AND screenshots.appName = ?"
                arguments.append(app)
            }

            sql += " ORDER BY screenshots.timestamp DESC LIMIT ?"
            arguments.append(limit)

            return try Screenshot.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    // MARK: - Cleanup

    /// Delete screenshots older than the specified date
    func deleteScreenshotsOlderThan(_ date: Date) throws -> [String] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // First get the image paths to delete
        let imagePaths = try dbQueue.read { db -> [String] in
            try String.fetchAll(
                db,
                sql: "SELECT imagePath FROM screenshots WHERE timestamp < ?",
                arguments: [date]
            )
        }

        // Then delete the records
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE timestamp < ?",
                arguments: [date]
            )
        }

        return imagePaths
    }

    /// Delete a specific screenshot
    func deleteScreenshot(id: Int64) throws -> String? {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Get the image path first
        let imagePath = try dbQueue.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT imagePath FROM screenshots WHERE id = ?",
                arguments: [id]
            )
        }

        // Delete the record
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM screenshots WHERE id = ?",
                arguments: [id]
            )
        }

        return imagePath
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
