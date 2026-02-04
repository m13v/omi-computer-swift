import AppKit
import AVFoundation
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

            // Notify that a new frame was captured (for live UI updates)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rewindFrameCaptured, object: nil)
            }

        } catch {
            logError("RewindIndexer: Failed to process frame: \(error)")
        }
    }

    /// Process a frame with additional metadata (focus status, etc.)
    func processFrame(_ frame: CapturedFrame, focusStatus: String?, extractedTasks: [String]?, advice: String?) async {
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

            // Notify that a new frame was captured (for live UI updates)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .rewindFrameCaptured, object: nil)
            }

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

    // MARK: - Database Rebuild

    /// Rebuild database from existing video files
    /// This scans all video chunks and recreates database entries
    /// - Parameter progressCallback: Called with progress (0.0 to 1.0) as rebuild proceeds
    func rebuildFromVideoFiles(progressCallback: @escaping (Double) -> Void) async throws {
        log("RewindIndexer: Starting database rebuild from video files...")

        // Ensure initialized
        if !isInitialized {
            try await initialize()
        }

        // Get all video chunk files
        let videoChunks = try await RewindStorage.shared.getAllVideoChunks()
        let totalChunks = videoChunks.count

        if totalChunks == 0 {
            log("RewindIndexer: No video chunks found to rebuild from")
            progressCallback(1.0)
            return
        }

        log("RewindIndexer: Found \(totalChunks) video chunks to process")

        var processedChunks = 0
        var totalFrames = 0

        for chunkInfo in videoChunks {
            // Extract frames from video chunk
            do {
                let frames = try await extractFramesFromChunk(chunkInfo)
                totalFrames += frames.count

                // Insert each frame into database
                for frame in frames {
                    let screenshot = Screenshot(
                        timestamp: frame.timestamp,
                        appName: frame.appName ?? "Unknown",
                        windowTitle: frame.windowTitle,
                        imagePath: "",
                        videoChunkPath: chunkInfo.relativePath,
                        frameOffset: frame.frameOffset,
                        ocrText: nil,
                        ocrDataJson: nil,
                        isIndexed: false  // Will need re-OCR
                    )

                    try await RewindDatabase.shared.insertScreenshot(screenshot)
                }
            } catch {
                logError("RewindIndexer: Failed to process chunk \(chunkInfo.relativePath): \(error)")
            }

            processedChunks += 1
            progressCallback(Double(processedChunks) / Double(totalChunks))
        }

        log("RewindIndexer: Rebuild complete - processed \(totalChunks) chunks, \(totalFrames) frames")
        progressCallback(1.0)
    }

    /// Extract frame metadata from a video chunk
    private func extractFramesFromChunk(_ chunkInfo: VideoChunkInfo) async throws -> [FrameMetadata] {
        // Parse the chunk filename to extract timestamp info
        // Format: chunk_YYYYMMDD_HHMMSS.hevc
        guard let timestamp = parseChunkTimestamp(chunkInfo.filename) else {
            return []
        }

        // Get frame count from video file
        let frameCount = try await getVideoFrameCount(at: chunkInfo.fullPath)

        // Create frame metadata for each frame (assuming 1 fps capture rate)
        var frames: [FrameMetadata] = []
        for i in 0..<frameCount {
            let frameTimestamp = timestamp.addingTimeInterval(Double(i))
            frames.append(FrameMetadata(
                timestamp: frameTimestamp,
                frameOffset: i,
                appName: nil,  // Can't recover app name from video
                windowTitle: nil
            ))
        }

        return frames
    }

    /// Parse timestamp from chunk filename
    private func parseChunkTimestamp(_ filename: String) -> Date? {
        // Expected format: chunk_YYYYMMDD_HHMMSS.hevc
        let pattern = /chunk_(\d{8})_(\d{6})\.hevc/
        guard let match = filename.firstMatch(of: pattern) else { return nil }

        let dateStr = String(match.1)
        let timeStr = String(match.2)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: dateStr + timeStr)
    }

    /// Get frame count from video file using AVFoundation
    private func getVideoFrameCount(at path: URL) async throws -> Int {
        let asset = AVAsset(url: path)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }

        let duration = try await asset.load(.duration)
        let frameRate = try await videoTrack.load(.nominalFrameRate)

        if frameRate > 0 {
            return Int(CMTimeGetSeconds(duration) * Double(frameRate))
        }

        // Fallback: assume 1 fps
        return Int(CMTimeGetSeconds(duration))
    }
}

/// Metadata for a frame extracted from video
private struct FrameMetadata {
    let timestamp: Date
    let frameOffset: Int
    let appName: String?
    let windowTitle: String?
}
