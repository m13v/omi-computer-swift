import Foundation
import GRDB
import CryptoKit

// MARK: - String SHA256 Extension

extension String {
    /// Compute SHA256 hash of the string (for OCR text deduplication)
    var sha256Hash: String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

/// Actor-based database manager for Rewind screenshots
actor RewindDatabase {
    static let shared = RewindDatabase()

    private var dbQueue: DatabaseQueue?

    /// Track if we recovered from corruption (for UI notification)
    private(set) var didRecoverFromCorruption = false

    /// Track initialization state to prevent concurrent init attempts
    private var initializationTask: Task<Void, Error>?

    // MARK: - Initialization

    private init() {}

    /// Whether the database has been successfully initialized
    var isInitialized: Bool { dbQueue != nil }

    /// Get the database queue for other storage actors
    func getDatabaseQueue() -> DatabaseQueue? {
        return dbQueue
    }

    /// Initialize the database with migrations
    /// Uses a shared task to prevent concurrent initialization attempts during recovery
    func initialize() async throws {
        // Already initialized
        guard dbQueue == nil else { return }

        // If initialization is in progress, wait for it
        if let task = initializationTask {
            return try await task.value
        }

        // Start initialization
        let task = Task {
            try await performInitialization()
        }
        initializationTask = task

        do {
            try await task.value
            // Clear task on success to release the Task object
            initializationTask = nil
        } catch {
            // Clear task on failure so retry is possible
            initializationTask = nil
            throw error
        }
    }

    /// Actual initialization logic (called only once at a time)
    private func performInitialization() async throws {
        guard dbQueue == nil else { return }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omiDir = appSupport.appendingPathComponent("Omi", isDirectory: true)

        // Create directory if needed
        try FileManager.default.createDirectory(at: omiDir, withIntermediateDirectories: true)

        let dbPath = omiDir.appendingPathComponent("omi.db").path
        log("RewindDatabase: Opening database at \(dbPath)")

        // Clean up stale WAL files that can cause disk I/O errors (SQLite error 10)
        // Skip the pre-open corruption check — it opens a separate DatabaseQueue that causes
        // lock contention with the main connection's PRAGMA journal_mode = WAL.
        // Post-migration verifyDatabaseIntegrity() already runs quick_check(1).
        if FileManager.default.fileExists(atPath: dbPath) {
            cleanupStaleWALFiles(at: dbPath)
        }

        var config = Configuration()
        config.prepareDatabase { db in
            // Try to enable WAL mode for better crash resistance and performance
            // WAL mode keeps writes in a separate file, making corruption much less likely
            // If WAL fails (disk I/O error, permissions), continue with default journal mode
            do {
                try db.execute(sql: "PRAGMA journal_mode = WAL")
                // synchronous = NORMAL is safe with WAL and much faster than FULL
                try db.execute(sql: "PRAGMA synchronous = NORMAL")
                // Auto-checkpoint every 1000 pages (~4MB) for WAL
                try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
            } catch {
                // WAL mode failed - log but continue with default journal mode
                // This can happen with disk I/O errors, permission issues, or full disk
                log("RewindDatabase: WAL mode unavailable (\(error.localizedDescription)), using default journal mode")
            }

            // Enable foreign keys (required)
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            // Set busy timeout to avoid "database is locked" errors (5 seconds)
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: dbPath, configuration: config)
        } catch {
            // If opening fails (e.g. disk I/O error on WAL), try once more without WAL files
            log("RewindDatabase: Failed to open database: \(error), cleaning WAL and retrying...")
            removeWALFiles(at: dbPath)
            queue = try DatabaseQueue(path: dbPath, configuration: config)
        }
        dbQueue = queue

        try migrate(queue)

        // Verify database integrity after migration
        try verifyDatabaseIntegrity(queue)

        log("RewindDatabase: Initialized successfully")

        // Run data migrations in background (non-blocking)
        Task {
            do {
                try await self.performOCRDataMigrationIfNeeded()
            } catch {
                log("RewindDatabase: OCR data migration failed: \(error)")
            }
        }
    }

    // MARK: - Corruption Detection & Recovery

    /// Check if database file is corrupted using quick_check
    /// Returns true if corrupted, false if OK
    private func checkDatabaseCorruption(at path: String) async -> Bool {
        // Open in read-write mode (NOT readonly) because WAL recovery requires write access.
        // Opening readonly with a pending WAL file causes SQLITE_CANTOPEN (error 14),
        // which is a false positive - the database isn't actually corrupted.
        do {
            let testQueue = try DatabaseQueue(path: path)
            let result = try await testQueue.read { db -> String in
                try String.fetchOne(db, sql: "PRAGMA quick_check(1)") ?? "ok"
            }
            return result.lowercased() != "ok"
        } catch {
            // If we can't even open the database, it's definitely corrupted
            log("RewindDatabase: Database failed to open for integrity check: \(error)")
            return true
        }
    }

    /// Clean up stale WAL/SHM files that can cause disk I/O errors (SQLite error 10, code 3850)
    /// This happens when the app crashes and leaves behind WAL files that are in a bad state
    private func cleanupStaleWALFiles(at dbPath: String) {
        let walPath = dbPath + "-wal"
        let shmPath = dbPath + "-shm"
        let fileManager = FileManager.default

        // Only clean up if WAL file exists and is empty (indicates stale/orphaned WAL)
        // Non-empty WAL files may contain uncommitted data we don't want to lose
        if fileManager.fileExists(atPath: walPath),
           let attrs = try? fileManager.attributesOfItem(atPath: walPath),
           let size = attrs[.size] as? Int64, size == 0 {
            try? fileManager.removeItem(atPath: walPath)
            try? fileManager.removeItem(atPath: shmPath)
            log("RewindDatabase: Cleaned up stale empty WAL/SHM files")
        }
    }

    /// Force-remove WAL/SHM files (last resort when database won't open)
    private func removeWALFiles(at dbPath: String) {
        let fileManager = FileManager.default
        for ext in ["-wal", "-shm"] {
            let filePath = dbPath + ext
            if fileManager.fileExists(atPath: filePath) {
                try? fileManager.removeItem(atPath: filePath)
                log("RewindDatabase: Removed \(ext) file for recovery")
            }
        }
    }

    /// Number of records recovered from corrupted database (0 if none)
    private(set) var recoveredRecordCount: Int = 0

    /// Handle corrupted database: attempt recovery, backup, and recreate
    private func handleCorruptedDatabase(at dbPath: String, in omiDir: URL) async throws {
        let fileManager = FileManager.default

        // Create backup directory
        let backupDir = omiDir.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)

        // Generate backup filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupPath = backupDir.appendingPathComponent("omi_corrupted_\(timestamp).db")

        // Backup the corrupted database (for potential manual recovery)
        log("RewindDatabase: Backing up corrupted database to \(backupPath.path)")
        try fileManager.copyItem(atPath: dbPath, toPath: backupPath.path)

        // Attempt to recover data from corrupted database
        let recoveredPath = omiDir.appendingPathComponent("omi_recovered.db").path
        let recoveredCount = await attemptDataRecovery(from: dbPath, to: recoveredPath)
        recoveredRecordCount = recoveredCount

        if recoveredCount > 0 {
            log("RewindDatabase: Recovered \(recoveredCount) screenshot records from corrupted database")
            // Use recovered database instead of creating fresh one
            try fileManager.removeItem(atPath: dbPath)
            try fileManager.moveItem(atPath: recoveredPath, toPath: dbPath)

            // Remove WAL/SHM files from corrupted database
            for ext in ["-wal", "-shm", "-journal"] {
                let file = dbPath + ext
                if fileManager.fileExists(atPath: file) {
                    try? fileManager.removeItem(atPath: file)
                }
            }

            log("RewindDatabase: Using recovered database with \(recoveredCount) records")
        } else {
            // No data recovered, remove corrupted database and start fresh
            log("RewindDatabase: No data could be recovered, creating fresh database")

            // Clean up recovery attempt if it exists
            if fileManager.fileExists(atPath: recoveredPath) {
                try? fileManager.removeItem(atPath: recoveredPath)
            }

            // Remove corrupted database and associated WAL/SHM files
            let filesToRemove = [
                dbPath,
                dbPath + "-wal",
                dbPath + "-shm",
                dbPath + "-journal"
            ]

            for file in filesToRemove {
                if fileManager.fileExists(atPath: file) {
                    try fileManager.removeItem(atPath: file)
                    log("RewindDatabase: Removed \(file)")
                }
            }
        }

        logError("RewindDatabase: Corrupted database backed up and removed. A fresh database will be created.")

        // Clean up old backups (keep only last 5)
        try await cleanupOldBackups(in: backupDir, keepCount: 5)
    }

    /// Attempt to recover data from a corrupted database using sqlite3 .recover
    /// Returns the number of screenshot records recovered
    private func attemptDataRecovery(from corruptedPath: String, to recoveredPath: String) async -> Int {
        let fileManager = FileManager.default

        // Remove any existing recovered database
        if fileManager.fileExists(atPath: recoveredPath) {
            try? fileManager.removeItem(atPath: recoveredPath)
        }

        // Run sqlite3 recovery in a detached task to avoid blocking the actor
        // Process.waitUntilExit() is synchronous and would deadlock the actor
        let (success, recoveredSQL) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Data), Never>) in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                process.arguments = [corruptedPath, ".recover"]

                let outputPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: (true, data))
                    } else {
                        continuation.resume(returning: (false, Data()))
                    }
                } catch {
                    continuation.resume(returning: (false, Data()))
                }
            }
        }

        if success && !recoveredSQL.isEmpty {
            // Import recovered SQL into new database (also in detached task)
            let importSuccess = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                Task.detached {
                    let importProcess = Process()
                    importProcess.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
                    importProcess.arguments = [recoveredPath]

                    let inputPipe = Pipe()
                    importProcess.standardInput = inputPipe
                    importProcess.standardOutput = FileHandle.nullDevice
                    importProcess.standardError = FileHandle.nullDevice

                    do {
                        try importProcess.run()
                        inputPipe.fileHandleForWriting.write(recoveredSQL)
                        inputPipe.fileHandleForWriting.closeFile()
                        importProcess.waitUntilExit()
                        continuation.resume(returning: importProcess.terminationStatus == 0)
                    } catch {
                        continuation.resume(returning: false)
                    }
                }
            }

            if importSuccess && fileManager.fileExists(atPath: recoveredPath) {
                return countRecoveredScreenshots(at: recoveredPath)
            }
        }

        // Fallback: Try to read screenshots table directly
        return await attemptDirectTableRecovery(from: corruptedPath, to: recoveredPath)
    }

    /// Fallback recovery: try to read the screenshots table directly
    private func attemptDirectTableRecovery(from corruptedPath: String, to recoveredPath: String) async -> Int {
        var config = Configuration()
        config.readonly = true

        do {
            let corruptedQueue = try DatabaseQueue(path: corruptedPath, configuration: config)

            // Try to read screenshot records
            let screenshots: [(timestamp: Date, appName: String, windowTitle: String?, videoChunkPath: String?, frameOffset: Int?)] = try await corruptedQueue.read { db in
                var results: [(Date, String, String?, String?, Int?)] = []

                // Try to fetch what we can from screenshots table
                let rows = try? Row.fetchAll(db, sql: """
                    SELECT timestamp, appName, windowTitle, videoChunkPath, frameOffset
                    FROM screenshots
                    ORDER BY timestamp DESC
                    LIMIT 100000
                """)

                for row in rows ?? [] {
                    if let timestamp: Date = row["timestamp"],
                       let appName: String = row["appName"] {
                        results.append((
                            timestamp,
                            appName,
                            row["windowTitle"] as String?,
                            row["videoChunkPath"] as String?,
                            row["frameOffset"] as Int?
                        ))
                    }
                }
                return results
            }

            if screenshots.isEmpty {
                return 0
            }

            // Create new database with recovered data
            let recoveredQueue = try DatabaseQueue(path: recoveredPath)

            try await recoveredQueue.write { db in
                // Create minimal screenshots table
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS screenshots (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        timestamp DATETIME NOT NULL,
                        appName TEXT NOT NULL,
                        windowTitle TEXT,
                        imagePath TEXT NOT NULL DEFAULT '',
                        videoChunkPath TEXT,
                        frameOffset INTEGER,
                        ocrText TEXT,
                        ocrDataJson TEXT,
                        isIndexed INTEGER NOT NULL DEFAULT 0,
                        focusStatus TEXT,
                        extractedTasksJson TEXT,
                        adviceJson TEXT
                    )
                """)

                // Insert recovered records
                for screenshot in screenshots {
                    try db.execute(sql: """
                        INSERT INTO screenshots (timestamp, appName, windowTitle, imagePath, videoChunkPath, frameOffset, isIndexed)
                        VALUES (?, ?, ?, '', ?, ?, 0)
                    """, arguments: [screenshot.timestamp, screenshot.appName, screenshot.windowTitle, screenshot.videoChunkPath, screenshot.frameOffset])
                }
            }

            return screenshots.count

        } catch {
            log("RewindDatabase: Direct table recovery failed: \(error)")
            return 0
        }
    }

    /// Count screenshots in recovered database
    private func countRecoveredScreenshots(at path: String) -> Int {
        do {
            let queue = try DatabaseQueue(path: path)
            return try queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM screenshots") ?? 0
            }
        } catch {
            return 0
        }
    }

    /// Clean up old database backups, keeping only the most recent ones
    private func cleanupOldBackups(in backupDir: URL, keepCount: Int) async throws {
        let fileManager = FileManager.default

        let files = try fileManager.contentsOfDirectory(
            at: backupDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "db" }

        // Sort by creation date, newest first
        let sortedFiles = files.sorted { file1, file2 in
            let date1 = (try? file1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let date2 = (try? file2.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return date1 > date2
        }

        // Remove files beyond keepCount
        for file in sortedFiles.dropFirst(keepCount) {
            try fileManager.removeItem(at: file)
            log("RewindDatabase: Removed old backup \(file.lastPathComponent)")
        }
    }

    /// Verify database integrity after successful initialization
    private func verifyDatabaseIntegrity(_ queue: DatabaseQueue) throws {
        try queue.read { db in
            // Quick integrity check on first page
            let result = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
            if result?.lowercased() != "ok" {
                throw RewindError.databaseCorrupted(message: result ?? "Unknown integrity error")
            }

            // Log journal mode (WAL preferred, but may fall back to delete/rollback)
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
            log("RewindDatabase: Journal mode is \(journalMode ?? "unknown")")

            // Log warning if not using WAL (less crash-resistant)
            if journalMode?.lowercased() != "wal" {
                log("RewindDatabase: WARNING - Not using WAL mode, database may be less crash-resistant")
            }
        }
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

        // Migration 9: Create normalized OCR storage tables
        migrator.registerMigration("createNormalizedOCR") { db in
            // Table 1: Unique OCR text content (deduplicated)
            try db.create(table: "ocr_texts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("text", .text).notNull().unique()
                t.column("textHash", .text).notNull()  // SHA256 for fast lookup
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "idx_ocr_texts_hash", on: "ocr_texts", columns: ["textHash"])

            // Table 2: Where each text block appeared (bounding boxes + metadata)
            try db.create(table: "ocr_occurrences") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ocrTextId", .integer).notNull()
                    .references("ocr_texts", onDelete: .cascade)
                t.column("screenshotId", .integer).notNull()
                    .references("screenshots", onDelete: .cascade)
                // Bounding box (normalized 0-1 coordinates)
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("width", .double).notNull()
                t.column("height", .double).notNull()
                // Metadata
                t.column("confidence", .double)
                t.column("blockOrder", .integer).notNull()  // For reconstructing full text in order
            }
            try db.create(index: "idx_ocr_occurrences_screenshot",
                          on: "ocr_occurrences", columns: ["screenshotId"])
            try db.create(index: "idx_ocr_occurrences_text",
                          on: "ocr_occurrences", columns: ["ocrTextId"])
            // Unique constraint: same text can't appear twice at same position in same screenshot
            try db.create(
                index: "idx_ocr_occurrences_unique",
                on: "ocr_occurrences",
                columns: ["ocrTextId", "screenshotId", "blockOrder"],
                unique: true
            )

            // FTS5 on unique texts only (much smaller index than full ocrText!)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE ocr_texts_fts USING fts5(
                    text,
                    content='ocr_texts',
                    content_rowid='id',
                    tokenize='unicode61'
                )
            """)

            // FTS sync triggers for ocr_texts
            try db.execute(sql: """
                CREATE TRIGGER ocr_texts_ai AFTER INSERT ON ocr_texts BEGIN
                    INSERT INTO ocr_texts_fts(rowid, text) VALUES (new.id, new.text);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER ocr_texts_ad AFTER DELETE ON ocr_texts BEGIN
                    INSERT INTO ocr_texts_fts(ocr_texts_fts, rowid, text)
                    VALUES ('delete', old.id, old.text);
                END
            """)

            // Migration status tracking table
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS migration_status (
                    name TEXT PRIMARY KEY,
                    completed INTEGER DEFAULT 0,
                    processedCount INTEGER DEFAULT 0,
                    startedAt DATETIME,
                    completedAt DATETIME
                )
            """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO migration_status (name, completed, startedAt)
                VALUES ('ocr_normalization', 0, datetime('now'))
            """)
        }

        // Migration 10: Create transcription storage tables for crash-safe recording
        migrator.registerMigration("createTranscriptionStorage") { db in
            // Recording sessions (parent)
            try db.create(table: "transcription_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("source", .text).notNull()              // 'desktop', 'omi', etc.
                t.column("language", .text).notNull().defaults(to: "en")
                t.column("timezone", .text).notNull().defaults(to: "UTC")
                t.column("inputDeviceName", .text)
                t.column("status", .text).notNull().defaults(to: "recording")  // recording|pending_upload|uploading|completed|failed
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("lastError", .text)
                t.column("backendId", .text)                     // Server conversation ID
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Transcript segments (child)
            try db.create(table: "transcription_segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .integer).notNull()
                    .references("transcription_sessions", onDelete: .cascade)
                t.column("speaker", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("startTime", .double).notNull()
                t.column("endTime", .double).notNull()
                t.column("segmentOrder", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            // Indexes for common queries
            try db.create(index: "idx_sessions_status", on: "transcription_sessions", columns: ["status"])
            try db.create(index: "idx_sessions_synced", on: "transcription_sessions", columns: ["backendSynced"])
            try db.create(index: "idx_segments_session", on: "transcription_segments", columns: ["sessionId"])
        }

        // Migration 11: Create live_notes table for AI-generated notes during recording
        migrator.registerMigration("createLiveNotes") { db in
            try db.create(table: "live_notes") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionId", .integer).notNull()
                    .references("transcription_sessions", onDelete: .cascade)
                t.column("text", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("isAiGenerated", .boolean).notNull().defaults(to: true)
                t.column("segmentStartOrder", .integer)  // Which segment triggered this note
                t.column("segmentEndOrder", .integer)    // End segment for context range
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Index for fetching notes by session
            try db.create(index: "idx_live_notes_session", on: "live_notes", columns: ["sessionId"])
        }

        // Migration 12: Expand transcription storage to match full ServerConversation schema
        migrator.registerMigration("expandTranscriptionSchema") { db in
            // Add structured data columns to transcription_sessions
            try db.alter(table: "transcription_sessions") { t in
                t.add(column: "title", .text)
                t.add(column: "overview", .text)
                t.add(column: "emoji", .text)
                t.add(column: "category", .text)
                t.add(column: "actionItemsJson", .text)
                t.add(column: "eventsJson", .text)
            }

            // Add additional conversation data columns
            try db.alter(table: "transcription_sessions") { t in
                t.add(column: "geolocationJson", .text)
                t.add(column: "photosJson", .text)
                t.add(column: "appsResultsJson", .text)
            }

            // Add conversation status and flags
            try db.alter(table: "transcription_sessions") { t in
                t.add(column: "conversationStatus", .text).defaults(to: "in_progress")
                t.add(column: "discarded", .boolean).defaults(to: false)
                t.add(column: "deleted", .boolean).defaults(to: false)
                t.add(column: "isLocked", .boolean).defaults(to: false)
                t.add(column: "starred", .boolean).defaults(to: false)
                t.add(column: "folderId", .text)
            }

            // Add backend segment data columns to transcription_segments
            try db.alter(table: "transcription_segments") { t in
                t.add(column: "segmentId", .text)
                t.add(column: "speakerLabel", .text)
                t.add(column: "isUser", .boolean).defaults(to: false)
                t.add(column: "personId", .text)
            }

            // Add index for backendId lookups (for syncing)
            try db.create(index: "idx_sessions_backendId", on: "transcription_sessions", columns: ["backendId"])

            // Add index for conversation status filtering
            try db.create(index: "idx_sessions_conversationStatus", on: "transcription_sessions", columns: ["conversationStatus"])

            // Add index for starred conversations
            try db.create(index: "idx_sessions_starred", on: "transcription_sessions", columns: ["starred"])
        }

        // Migration 13: Create task dedup log table for AI deletion tracking
        migrator.registerMigration("createTaskDedupLog") { db in
            try db.create(table: "task_dedup_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("deletedTaskId", .text).notNull()
                t.column("deletedDescription", .text).notNull()
                t.column("keptTaskId", .text).notNull()
                t.column("keptDescription", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("deletedAt", .datetime).notNull()
            }
            try db.create(index: "idx_dedup_log_deleted_at",
                          on: "task_dedup_log", columns: ["deletedAt"])
        }

        // Migration 14: Create unified memories table for local-first pattern
        // Stores all memories (extracted, advice/tips, focus-tagged) with bidirectional sync
        migrator.registerMigration("createMemoriesTable") { db in
            try db.create(table: "memories") { t in
                t.autoIncrementedPrimaryKey("id")

                // Backend sync fields
                t.column("backendId", .text).unique()       // Server memory ID
                t.column("backendSynced", .boolean).notNull().defaults(to: false)

                // Core ServerMemory fields
                t.column("content", .text).notNull()
                t.column("category", .text).notNull()       // system, interesting, manual
                t.column("tagsJson", .text)                 // JSON array: ["tips"], ["focus", "focused"]
                t.column("visibility", .text).notNull().defaults(to: "private")
                t.column("reviewed", .boolean).notNull().defaults(to: false)
                t.column("userReview", .boolean)
                t.column("manuallyAdded", .boolean).notNull().defaults(to: false)
                t.column("scoring", .text)
                t.column("source", .text)                   // desktop, omi, screenshot, phone
                t.column("conversationId", .text)

                // Desktop extraction fields
                t.column("screenshotId", .integer)
                    .references("screenshots", onDelete: .setNull)
                t.column("confidence", .double)
                t.column("reasoning", .text)
                t.column("sourceApp", .text)
                t.column("contextSummary", .text)
                t.column("currentActivity", .text)
                t.column("inputDeviceName", .text)

                // Status flags
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("isDismissed", .boolean).notNull().defaults(to: false)
                t.column("deleted", .boolean).notNull().defaults(to: false)

                // Timestamps
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Indexes for common queries
            try db.create(index: "idx_memories_backend_id", on: "memories", columns: ["backendId"])
            try db.create(index: "idx_memories_created", on: "memories", columns: ["createdAt"])
            try db.create(index: "idx_memories_category", on: "memories", columns: ["category"])
            try db.create(index: "idx_memories_synced", on: "memories", columns: ["backendSynced"])
            try db.create(index: "idx_memories_screenshot", on: "memories", columns: ["screenshotId"])
            try db.create(index: "idx_memories_deleted", on: "memories", columns: ["deleted"])

            // Migrate existing memories from proactive_extractions
            // Use INSERT OR IGNORE to handle duplicate backendIds gracefully
            // For records with NULL backendId (unsynced), we insert all of them
            // For records with non-NULL backendId (synced), we keep only the first one per backendId
            try db.execute(sql: """
                INSERT OR IGNORE INTO memories (
                    backendId, backendSynced, content, category, tagsJson, visibility,
                    reviewed, manuallyAdded, source, screenshotId, confidence, reasoning,
                    sourceApp, contextSummary, isRead, isDismissed, deleted, createdAt, updatedAt
                )
                SELECT
                    backendId, backendSynced, content,
                    CASE WHEN category IS NULL THEN 'system' ELSE category END,
                    CASE
                        WHEN type = 'advice' THEN json_array('tips', COALESCE(category, 'other'))
                        ELSE NULL
                    END,
                    'private',
                    0, 0, 'screenshot', screenshotId, confidence, reasoning,
                    sourceApp, contextSummary, isRead, isDismissed, 0, createdAt, updatedAt
                FROM proactive_extractions
                WHERE type IN ('memory', 'advice')
                ORDER BY createdAt DESC
            """)
        }

        // Migration 15: Create action_items table for tasks with bidirectional sync
        migrator.registerMigration("createActionItemsTable") { db in
            try db.create(table: "action_items") { t in
                t.autoIncrementedPrimaryKey("id")

                // Backend sync fields
                t.column("backendId", .text).unique()       // Server action item ID
                t.column("backendSynced", .boolean).notNull().defaults(to: false)

                // Core ActionItem fields
                t.column("description", .text).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("source", .text)                   // screenshot, conversation, omi
                t.column("conversationId", .text)
                t.column("priority", .text)                 // high, medium, low
                t.column("category", .text)
                t.column("dueAt", .datetime)

                // Desktop extraction fields
                t.column("screenshotId", .integer)
                    .references("screenshots", onDelete: .setNull)
                t.column("confidence", .double)
                t.column("sourceApp", .text)
                t.column("contextSummary", .text)
                t.column("currentActivity", .text)
                t.column("metadataJson", .text)             // Additional extraction metadata

                // Timestamps
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            // Indexes for common queries
            try db.create(index: "idx_action_items_backend_id", on: "action_items", columns: ["backendId"])
            try db.create(index: "idx_action_items_created", on: "action_items", columns: ["createdAt"])
            try db.create(index: "idx_action_items_completed", on: "action_items", columns: ["completed"])
            try db.create(index: "idx_action_items_synced", on: "action_items", columns: ["backendSynced"])
            try db.create(index: "idx_action_items_deleted", on: "action_items", columns: ["deleted"])
            try db.create(index: "idx_action_items_due", on: "action_items", columns: ["dueAt"])

            // Migrate existing tasks from proactive_extractions
            // Use INSERT OR IGNORE to handle duplicate backendIds gracefully
            try db.execute(sql: """
                INSERT OR IGNORE INTO action_items (
                    backendId, backendSynced, description, completed, deleted, source,
                    priority, category, screenshotId, confidence, sourceApp, contextSummary,
                    createdAt, updatedAt
                )
                SELECT
                    backendId, backendSynced, content, 0, 0, 'screenshot',
                    priority, category, screenshotId, confidence, sourceApp, contextSummary,
                    createdAt, updatedAt
                FROM proactive_extractions
                WHERE type = 'task'
                ORDER BY createdAt DESC
            """)
        }

        // Migration 16: Add tagsJson column to action_items for multi-tag support
        migrator.registerMigration("addActionItemTagsJson") { db in
            try db.alter(table: "action_items") { t in
                t.add(column: "tagsJson", .text)
            }

            // Migrate existing rows: populate tagsJson from category
            try db.execute(sql: """
                UPDATE action_items SET tagsJson = json_array(category) WHERE category IS NOT NULL
            """)
        }

        // Migration 17: Add deletedBy column to action_items for tracking who deleted
        migrator.registerMigration("addActionItemDeletedBy") { db in
            try db.alter(table: "action_items") { t in
                t.add(column: "deletedBy", .text)  // "user", "ai_dedup"
            }
        }

        // Migration 18: Add embedding column to action_items for vector search
        migrator.registerMigration("addActionItemEmbedding") { db in
            try db.alter(table: "action_items") { t in
                t.add(column: "embedding", .blob)  // 768 Float32s = 3072 bytes
            }
        }

        // Migration 19: Create FTS5 virtual table on action_items.description for keyword search
        migrator.registerMigration("createActionItemsFTS") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE action_items_fts USING fts5(
                    description,
                    content='action_items',
                    content_rowid='id',
                    tokenize='unicode61'
                )
                """)

            // Sync triggers
            try db.execute(sql: """
                CREATE TRIGGER action_items_fts_ai AFTER INSERT ON action_items BEGIN
                    INSERT INTO action_items_fts(rowid, description)
                    VALUES (new.id, new.description);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER action_items_fts_ad AFTER DELETE ON action_items BEGIN
                    INSERT INTO action_items_fts(action_items_fts, rowid, description)
                    VALUES ('delete', old.id, old.description);
                END
                """)

            try db.execute(sql: """
                CREATE TRIGGER action_items_fts_au AFTER UPDATE ON action_items BEGIN
                    INSERT INTO action_items_fts(action_items_fts, rowid, description)
                    VALUES ('delete', old.id, old.description);
                    INSERT INTO action_items_fts(rowid, description)
                    VALUES (new.id, new.description);
                END
                """)

            // Populate with existing data
            try db.execute(sql: """
                INSERT INTO action_items_fts(rowid, description)
                SELECT id, description FROM action_items
                """)
        }

        // Migration 20: Create ai_user_profiles table for daily AI-generated user profile history
        migrator.registerMigration("createAIUserProfiles") { db in
            try db.create(table: "ai_user_profiles") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("profileText", .text).notNull()
                t.column("dataSourcesUsed", .integer).notNull()
                t.column("backendSynced", .boolean).notNull().defaults(to: false)
                t.column("generatedAt", .datetime).notNull()
            }

            try db.create(index: "idx_ai_user_profiles_generated",
                          on: "ai_user_profiles", columns: ["generatedAt"])
        }

        // Migration 21: Clear AI user profiles generated with old prompt (contained hallucinations)
        migrator.registerMigration("clearAIUserProfilesV1") { db in
            try db.execute(sql: "DELETE FROM ai_user_profiles")
        }

        try migrator.migrate(queue)
    }

    // MARK: - OCR Data Migration

    /// Migrate existing OCR data to normalized tables (runs once after schema migration)
    func performOCRDataMigrationIfNeeded() async throws {
        guard let dbQueue = dbQueue else { return }

        // Check if already migrated
        let isComplete = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT completed FROM migration_status
                WHERE name = 'ocr_normalization'
            """) ?? 1
        }
        guard isComplete == 0 else {
            log("RewindDatabase: OCR normalization already complete, skipping")
            return
        }

        log("RewindDatabase: Starting OCR normalization migration...")

        // Process in batches to avoid memory issues
        let batchSize = 500
        var offset = 0
        var totalProcessed = 0
        var totalBlocks = 0

        while true {
            let currentOffset = offset
            let batch = try await dbQueue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, ocrDataJson FROM screenshots
                    WHERE ocrDataJson IS NOT NULL AND ocrDataJson != ''
                    ORDER BY id
                    LIMIT ? OFFSET ?
                """, arguments: [batchSize, currentOffset])
            }

            if batch.isEmpty { break }

            // Extract data from rows before entering the write closure (Row is not Sendable)
            let batchData: [(id: Int64, json: String)] = batch.compactMap { row in
                guard let id: Int64 = row["id"],
                      let json: String = row["ocrDataJson"]
                else { return nil }
                return (id, json)
            }

            let batchBlocks = try await dbQueue.write { db -> Int in
                var blocksInBatch = 0
                for (screenshotId, jsonString) in batchData {
                    guard let jsonData = jsonString.data(using: .utf8)
                    else { continue }

                    // Parse OCR result
                    let ocrResult: OCRResult
                    do {
                        ocrResult = try JSONDecoder().decode(OCRResult.self, from: jsonData)
                    } catch {
                        continue  // Skip malformed JSON
                    }

                    for (index, block) in ocrResult.blocks.enumerated() {
                        // Skip empty/garbage text (< 3 chars)
                        guard block.text.count >= 3 else { continue }

                        let textHash = block.text.sha256Hash

                        // Insert or get existing text ID
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO ocr_texts (text, textHash, createdAt)
                            VALUES (?, ?, datetime('now'))
                        """, arguments: [block.text, textHash])

                        guard let textId = try Int64.fetchOne(db, sql: """
                            SELECT id FROM ocr_texts WHERE textHash = ?
                        """, arguments: [textHash]) else { continue }

                        // Insert occurrence (link text to screenshot with bounding box)
                        try db.execute(sql: """
                            INSERT INTO ocr_occurrences
                            (ocrTextId, screenshotId, x, y, width, height, confidence, blockOrder)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            textId, screenshotId,
                            block.x, block.y, block.width, block.height,
                            block.confidence, index
                        ])

                        blocksInBatch += 1
                    }
                }
                return blocksInBatch
            }

            offset += batchSize
            totalProcessed += batch.count
            totalBlocks += batchBlocks

            if totalProcessed % 5000 == 0 {
                log("RewindDatabase: Migrated \(totalProcessed) screenshots, \(totalBlocks) text blocks...")
            }
        }

        // Rebuild FTS index and mark complete
        let finalProcessed = totalProcessed
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO ocr_texts_fts(ocr_texts_fts) VALUES('rebuild')
            """)
            try db.execute(sql: """
                UPDATE migration_status
                SET completed = 1, processedCount = ?, completedAt = datetime('now')
                WHERE name = 'ocr_normalization'
            """, arguments: [finalProcessed])
        }

        // Log final stats
        let stats = try await dbQueue.read { db -> (uniqueTexts: Int, occurrences: Int) in
            let texts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_texts") ?? 0
            let occurrences = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_occurrences") ?? 0
            return (texts, occurrences)
        }

        log("RewindDatabase: OCR normalization complete!")
        log("  - Processed \(totalProcessed) screenshots")
        log("  - Created \(stats.uniqueTexts) unique text entries")
        log("  - Created \(stats.occurrences) occurrence records")
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
    /// Also writes to normalized ocr_texts/ocr_occurrences tables for deduplication
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
            // Legacy: Update screenshots table (for backwards compatibility)
            try db.execute(
                sql: "UPDATE screenshots SET ocrText = ?, ocrDataJson = ?, isIndexed = 1 WHERE id = ?",
                arguments: [ocrResult.fullText, ocrDataJson, id]
            )

            // New: Write to normalized tables for deduplication
            // Check if normalized tables exist (migration may not have run yet)
            let tableExists = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type='table' AND name='ocr_texts'
            """) ?? 0 > 0

            guard tableExists else { return }

            for (index, block) in ocrResult.blocks.enumerated() {
                // Skip empty/garbage text (< 3 chars)
                guard block.text.count >= 3 else { continue }

                let textHash = block.text.sha256Hash

                // Insert or get existing text ID
                try db.execute(sql: """
                    INSERT OR IGNORE INTO ocr_texts (text, textHash, createdAt)
                    VALUES (?, ?, datetime('now'))
                """, arguments: [block.text, textHash])

                guard let textId = try Int64.fetchOne(db, sql: """
                    SELECT id FROM ocr_texts WHERE textHash = ?
                """, arguments: [textHash]) else { continue }

                // Insert occurrence (ignore if duplicate)
                try db.execute(sql: """
                    INSERT OR IGNORE INTO ocr_occurrences
                    (ocrTextId, screenshotId, x, y, width, height, confidence, blockOrder)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    textId, id,
                    block.x, block.y, block.width, block.height,
                    block.confidence, index
                ])
            }
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

    /// Full-text search using normalized OCR tables (more efficient, deduplicated)
    /// Falls back to legacy search if normalized tables not yet populated
    func searchNormalized(
        query: String,
        appFilter: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        limit: Int = 100
    ) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        // Check if normalized tables are populated
        let isNormalized = try dbQueue.read { db in
            let migrationComplete = try Int.fetchOne(db, sql: """
                SELECT completed FROM migration_status
                WHERE name = 'ocr_normalization'
            """) ?? 0
            return migrationComplete == 1
        }

        // Fall back to legacy search if not yet migrated
        guard isNormalized else {
            return try search(query: query, appFilter: appFilter, startDate: startDate, endDate: endDate, limit: limit)
        }

        let expandedQuery = expandSearchQuery(query)
        guard !expandedQuery.isEmpty else {
            return []
        }

        return try dbQueue.read { db in
            var sql = """
                SELECT DISTINCT s.*
                FROM screenshots s
                JOIN ocr_occurrences o ON o.screenshotId = s.id
                JOIN ocr_texts t ON t.id = o.ocrTextId
                JOIN ocr_texts_fts fts ON fts.rowid = t.id
                WHERE ocr_texts_fts MATCH ?
                """
            var arguments: [DatabaseValueConvertible] = [expandedQuery]

            if let app = appFilter {
                sql += " AND s.appName = ?"
                arguments.append(app)
            }

            if let start = startDate {
                sql += " AND s.timestamp >= ?"
                arguments.append(start)
            }

            if let end = endDate {
                sql += " AND s.timestamp <= ?"
                arguments.append(end)
            }

            sql += " ORDER BY bm25(ocr_texts_fts) ASC, s.timestamp DESC LIMIT ?"
            arguments.append(limit)

            return try Screenshot.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Get all OCR text blocks for a screenshot (from normalized tables)
    func getOCRBlocks(for screenshotId: Int64) throws -> [(text: String, x: Double, y: Double, width: Double, height: Double)] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.text, o.x, o.y, o.width, o.height
                FROM ocr_occurrences o
                JOIN ocr_texts t ON t.id = o.ocrTextId
                WHERE o.screenshotId = ?
                ORDER BY o.blockOrder
            """, arguments: [screenshotId]).map { row in
                (
                    text: row["text"] as String,
                    x: row["x"] as Double,
                    y: row["y"] as Double,
                    width: row["width"] as Double,
                    height: row["height"] as Double
                )
            }
        }
    }

    /// Get screenshots where specific text appeared (reverse lookup)
    func getScreenshotsContainingText(_ text: String, limit: Int = 50) throws -> [Screenshot] {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        let textHash = text.sha256Hash

        return try dbQueue.read { db in
            try Screenshot.fetchAll(db, sql: """
                SELECT s.*
                FROM screenshots s
                JOIN ocr_occurrences o ON o.screenshotId = s.id
                JOIN ocr_texts t ON t.id = o.ocrTextId
                WHERE t.textHash = ?
                ORDER BY s.timestamp DESC
                LIMIT ?
            """, arguments: [textHash, limit])
        }
    }

    /// Get normalized OCR storage statistics
    func getNormalizedOCRStats() throws -> (uniqueTexts: Int, totalOccurrences: Int, compressionRatio: Double) {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        return try dbQueue.read { db in
            let uniqueTexts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_texts") ?? 0
            let totalOccurrences = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ocr_occurrences") ?? 0

            // Compression ratio: how many occurrences per unique text
            let ratio = uniqueTexts > 0 ? Double(totalOccurrences) / Double(uniqueTexts) : 1.0

            return (uniqueTexts, totalOccurrences, ratio)
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

    /// Delete all screenshots from a corrupted video chunk
    /// Returns the number of deleted records
    func deleteScreenshotsFromVideoChunk(videoChunkPath: String) throws -> Int {
        guard let dbQueue = dbQueue else {
            throw RewindError.databaseNotInitialized
        }

        let deletedCount = try dbQueue.write { db -> Int in
            // Get count before deletion
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM screenshots WHERE videoChunkPath = ?",
                arguments: [videoChunkPath]
            ) ?? 0

            // Delete all records for this chunk
            try db.execute(
                sql: "DELETE FROM screenshots WHERE videoChunkPath = ?",
                arguments: [videoChunkPath]
            )

            return count
        }

        if deletedCount > 0 {
            log("RewindDatabase: Deleted \(deletedCount) screenshots from corrupted chunk: \(videoChunkPath)")
        }

        return deletedCount
    }
}
