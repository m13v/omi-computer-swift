import AppKit
import Foundation

/// Coordinates the capture → storage → database → OCR pipeline for Rewind
actor RewindIndexer {
    static let shared = RewindIndexer()

    private var isInitialized = false

    // MARK: - Initialization

    private init() {}

    /// Initialize all Rewind services
    func initialize() async throws {
        guard !isInitialized else { return }

        log("RewindIndexer: Initializing...")

        // Initialize database
        try await RewindDatabase.shared.initialize()

        // Initialize storage
        try await RewindStorage.shared.initialize()

        isInitialized = true
        log("RewindIndexer: Initialized successfully")
    }

    // MARK: - Frame Processing

    /// Process a captured frame from ProactiveAssistantsPlugin
    func processFrame(_ frame: CapturedFrame) async {
        // Check if Rewind is enabled
        guard RewindSettings.shared.isEnabled else { return }

        // Ensure initialized
        if !isInitialized {
            do {
                try await initialize()
            } catch {
                logError("RewindIndexer: Failed to initialize: \(error)")
                return
            }
        }

        do {
            // Convert JPEG to CGImage for video encoding
            guard let nsImage = NSImage(data: frame.jpegData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                logError("RewindIndexer: Failed to create CGImage from frame data")
                return
            }

            // Add frame to video encoder
            let encodedFrame = try await VideoChunkEncoder.shared.addFrame(
                image: cgImage,
                timestamp: frame.captureTime
            )

            // Run OCR directly on the JPEG data (avoids video extraction issues)
            var ocrText: String?
            var ocrDataJson: String?
            var isIndexed = false

            do {
                let ocrResult = try await RewindOCRService.shared.extractTextWithBounds(from: frame.jpegData)
                ocrText = ocrResult.fullText
                if let data = try? JSONEncoder().encode(ocrResult) {
                    ocrDataJson = String(data: data, encoding: .utf8)
                }
                isIndexed = true
            } catch {
                logError("RewindIndexer: OCR failed for frame: \(error)")
            }

            // Create database record with video reference and OCR results
            let screenshot = Screenshot(
                timestamp: frame.captureTime,
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                imagePath: "",
                videoChunkPath: encodedFrame?.videoChunkPath,
                frameOffset: encodedFrame?.frameOffset,
                ocrText: ocrText,
                ocrDataJson: ocrDataJson,
                isIndexed: isIndexed
            )

            try await RewindDatabase.shared.insertScreenshot(screenshot)

        } catch {
            logError("RewindIndexer: Failed to process frame: \(error)")
        }
    }

    /// Process a frame with additional metadata (focus status, etc.)
    func processFrame(_ frame: CapturedFrame, focusStatus: String?, extractedTasks: [String]?, advice: String?) async {
        guard RewindSettings.shared.isEnabled else { return }

        if !isInitialized {
            do {
                try await initialize()
            } catch {
                logError("RewindIndexer: Failed to initialize: \(error)")
                return
            }
        }

        do {
            // Convert JPEG to CGImage for video encoding
            guard let nsImage = NSImage(data: frame.jpegData),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                logError("RewindIndexer: Failed to create CGImage from frame data")
                return
            }

            // Add frame to video encoder
            let encodedFrame = try await VideoChunkEncoder.shared.addFrame(
                image: cgImage,
                timestamp: frame.captureTime
            )

            // Run OCR directly on the JPEG data (avoids video extraction issues)
            var ocrText: String?
            var ocrDataJson: String?
            var isIndexed = false

            do {
                let ocrResult = try await RewindOCRService.shared.extractTextWithBounds(from: frame.jpegData)
                ocrText = ocrResult.fullText
                if let data = try? JSONEncoder().encode(ocrResult) {
                    ocrDataJson = String(data: data, encoding: .utf8)
                }
                isIndexed = true
            } catch {
                logError("RewindIndexer: OCR failed for frame with metadata: \(error)")
            }

            // Encode tasks and advice as JSON
            var tasksJson: String?
            if let tasks = extractedTasks, !tasks.isEmpty {
                let data = try JSONEncoder().encode(tasks)
                tasksJson = String(data: data, encoding: .utf8)
            }

            let adviceJson: String? = advice

            let screenshot = Screenshot(
                timestamp: frame.captureTime,
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                imagePath: "",
                videoChunkPath: encodedFrame?.videoChunkPath,
                frameOffset: encodedFrame?.frameOffset,
                ocrText: ocrText,
                ocrDataJson: ocrDataJson,
                isIndexed: isIndexed,
                focusStatus: focusStatus,
                extractedTasksJson: tasksJson,
                adviceJson: adviceJson
            )

            try await RewindDatabase.shared.insertScreenshot(screenshot)

        } catch {
            logError("RewindIndexer: Failed to process frame with metadata: \(error)")
        }
    }

    // MARK: - Cleanup

    /// Run cleanup to remove old screenshots
    func runCleanup() async {
        let retentionDays = RewindSettings.shared.retentionDays

        do {
            // Get cutoff date
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

            // Delete from database and get paths to delete
            let deleteResult = try await RewindDatabase.shared.deleteScreenshotsOlderThan(cutoffDate)

            // Delete legacy JPEG files
            if !deleteResult.imagePaths.isEmpty {
                try await RewindStorage.shared.deleteScreenshots(relativePaths: deleteResult.imagePaths)
            }

            // Delete orphaned video chunks (all frames deleted)
            if !deleteResult.orphanedVideoChunks.isEmpty {
                try await RewindStorage.shared.deleteVideoChunks(relativePaths: deleteResult.orphanedVideoChunks)
            }

            // Clean up empty directories
            try await RewindStorage.shared.cleanupEmptyDirectories()

            let totalDeleted = deleteResult.imagePaths.count + deleteResult.orphanedVideoChunks.count
            if totalDeleted > 0 {
                log("RewindIndexer: Cleaned up \(deleteResult.imagePaths.count) old JPEGs and \(deleteResult.orphanedVideoChunks.count) video chunks")
            }

        } catch {
            logError("RewindIndexer: Cleanup failed: \(error)")
        }
    }

    /// Stop the indexer
    func stop() async {
        // Flush any pending video frames before stopping
        do {
            _ = try await VideoChunkEncoder.shared.flushCurrentChunk()
        } catch {
            logError("RewindIndexer: Failed to flush video chunk: \(error)")
        }

        log("RewindIndexer: Stopped")
    }

    // MARK: - Statistics

    /// Get indexer statistics
    func getStats() async -> (total: Int, indexed: Int, storageSize: Int64)? {
        do {
            let dbStats = try await RewindDatabase.shared.getStats()
            let storageSize = try await RewindStorage.shared.getTotalStorageSize()
            return (dbStats.total, dbStats.indexed, storageSize)
        } catch {
            logError("RewindIndexer: Failed to get stats: \(error)")
            return nil
        }
    }
}
