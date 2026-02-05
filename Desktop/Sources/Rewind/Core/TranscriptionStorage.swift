import Foundation
import GRDB

/// Actor-based storage manager for transcription sessions and segments
/// Provides crash-safe persistence for transcription data during recording
actor TranscriptionStorage {
    static let shared = TranscriptionStorage()

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
            throw TranscriptionStorageError.databaseNotInitialized
        }

        _dbQueue = db
        isInitialized = true
        return db
    }

    // MARK: - Session Lifecycle

    /// Start a new transcription session
    /// - Returns: The new session's ID
    @discardableResult
    func startSession(
        source: String,
        language: String = "en",
        timezone: String = "UTC",
        inputDeviceName: String? = nil
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        let session = TranscriptionSessionRecord(
            startedAt: Date(),
            source: source,
            language: language,
            timezone: timezone,
            inputDeviceName: inputDeviceName,
            status: .recording
        )

        let record = try await db.write { database in
            try session.inserted(database)
        }

        log("TranscriptionStorage: Started session \(record.id ?? -1) (source: \(source), device: \(inputDeviceName ?? "unknown"))")
        return record.id!
    }

    /// Mark session as finished (recording complete, ready for upload)
    func finishSession(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.finishedAt = Date()
            record.status = .pendingUpload
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Finished session \(id)")
    }

    /// Mark session as pending upload
    func markSessionPendingUpload(id: Int64) async throws {
        try await updateSessionStatus(id: id, status: .pendingUpload)
    }

    /// Mark session as currently uploading
    func markSessionUploading(id: Int64) async throws {
        try await updateSessionStatus(id: id, status: .uploading)
    }

    /// Mark session as completed (uploaded successfully)
    func markSessionCompleted(id: Int64, backendId: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.status = .completed
            record.backendId = backendId
            record.backendSynced = true
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Completed session \(id) (backendId: \(backendId))")
    }

    /// Mark session as failed with error
    func markSessionFailed(id: Int64, error: String) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.status = .failed
            record.lastError = error
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Failed session \(id) (error: \(error))")
    }

    /// Increment retry count for a session
    func incrementRetryCount(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.retryCount += 1
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Incremented retry count for session \(id)")
    }

    /// Delete a session and its segments
    func deleteSession(id: Int64) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM transcription_sessions WHERE id = ?",
                arguments: [id]
            )
        }

        log("TranscriptionStorage: Deleted session \(id)")
    }

    /// Update session status helper
    private func updateSessionStatus(id: Int64, status: TranscriptionSessionStatus) async throws {
        let db = try await ensureInitialized()

        try await db.write { database in
            guard var record = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                throw TranscriptionStorageError.sessionNotFound
            }

            record.status = status
            record.updatedAt = Date()
            try record.update(database)
        }

        log("TranscriptionStorage: Updated session \(id) status to \(status.rawValue)")
    }

    // MARK: - Segment Operations

    /// Append a new segment to a session
    @discardableResult
    func appendSegment(
        sessionId: Int64,
        speaker: Int,
        text: String,
        startTime: Double,
        endTime: Double
    ) async throws -> Int64 {
        let db = try await ensureInitialized()

        // Get the next segment order
        let segmentOrder = try await db.read { database -> Int in
            try Int.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(segmentOrder), -1) + 1 FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }

        let segment = TranscriptionSegmentRecord(
            sessionId: sessionId,
            speaker: speaker,
            text: text,
            startTime: startTime,
            endTime: endTime,
            segmentOrder: segmentOrder
        )

        let record = try await db.write { database in
            try segment.inserted(database)
        }

        log("TranscriptionStorage: Appended segment \(record.id ?? -1) to session \(sessionId) (speaker: \(speaker), \(String(format: "%.1f", startTime))s-\(String(format: "%.1f", endTime))s)")
        return record.id!
    }

    /// Get all segments for a session ordered by segmentOrder
    func getSegments(sessionId: Int64) async throws -> [TranscriptionSegmentRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSegmentRecord
                .filter(Column("sessionId") == sessionId)
                .order(Column("segmentOrder").asc)
                .fetchAll(database)
        }
    }

    /// Get segment count for a session
    func getSegmentCount(sessionId: Int64) async throws -> Int {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_segments WHERE sessionId = ?",
                arguments: [sessionId]
            ) ?? 0
        }
    }

    // MARK: - Queries

    /// Get a session by ID
    func getSession(id: Int64) async throws -> TranscriptionSessionRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord.fetchOne(database, key: id)
        }
    }

    /// Get the currently active recording session (if any)
    func getActiveSession() async throws -> TranscriptionSessionRecord? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.recording.rawValue)
                .order(Column("createdAt").desc)
                .fetchOne(database)
        }
    }

    /// Get sessions pending upload
    func getPendingUploadSessions() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.pendingUpload.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get failed sessions that can be retried
    func getFailedSessions(maxRetries: Int = 5) async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.failed.rawValue)
                .filter(Column("retryCount") < maxRetries)
                .order(Column("updatedAt").asc)
                .fetchAll(database)
        }
    }

    /// Get sessions that were left in "recording" status (crashed)
    func getCrashedSessions() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(Column("status") == TranscriptionSessionStatus.recording.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get a session with its segments
    func getSessionWithSegments(id: Int64) async throws -> TranscriptionSessionWithSegments? {
        let db = try await ensureInitialized()

        return try await db.read { database in
            guard let session = try TranscriptionSessionRecord.fetchOne(database, key: id) else {
                return nil
            }

            let segments = try TranscriptionSegmentRecord
                .filter(Column("sessionId") == id)
                .order(Column("segmentOrder").asc)
                .fetchAll(database)

            return TranscriptionSessionWithSegments(session: session, segments: segments)
        }
    }

    /// Get all sessions needing recovery (crashed, pending, or failed with retries left)
    func getSessionsNeedingRecovery() async throws -> [TranscriptionSessionRecord] {
        let db = try await ensureInitialized()

        return try await db.read { database in
            try TranscriptionSessionRecord
                .filter(
                    Column("status") == TranscriptionSessionStatus.recording.rawValue ||
                    Column("status") == TranscriptionSessionStatus.pendingUpload.rawValue ||
                    (Column("status") == TranscriptionSessionStatus.failed.rawValue && Column("retryCount") < 5)
                )
                .order(Column("createdAt").asc)
                .fetchAll(database)
        }
    }

    /// Get storage statistics
    func getStats() async throws -> (totalSessions: Int, pendingCount: Int, failedCount: Int, completedCount: Int) {
        let db = try await ensureInitialized()

        return try await db.read { database in
            let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcription_sessions") ?? 0
            let pending = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.pendingUpload.rawValue]
            ) ?? 0
            let failed = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.failed.rawValue]
            ) ?? 0
            let completed = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM transcription_sessions WHERE status = ?",
                arguments: [TranscriptionSessionStatus.completed.rawValue]
            ) ?? 0

            return (total, pending, failed, completed)
        }
    }
}
