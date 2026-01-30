import Foundation

/// Coordinates the capture → storage → database → OCR pipeline for Rewind
actor RewindIndexer {
    static let shared = RewindIndexer()

    private var isInitialized = false
    private var isProcessingOCR = false
    private var ocrTask: Task<Void, Never>?

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

        // Start background OCR processing
        startOCRProcessing()
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
            // 1. Save the screenshot to disk
            let imagePath = try await RewindStorage.shared.saveScreenshot(
                jpegData: frame.jpegData,
                timestamp: frame.captureTime
            )

            // 2. Create database record
            let screenshot = Screenshot(
                timestamp: frame.captureTime,
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                imagePath: imagePath,
                isIndexed: false
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
            let imagePath = try await RewindStorage.shared.saveScreenshot(
                jpegData: frame.jpegData,
                timestamp: frame.captureTime
            )

            // Encode tasks and advice as JSON
            var tasksJson: String? = nil
            if let tasks = extractedTasks, !tasks.isEmpty {
                let data = try JSONEncoder().encode(tasks)
                tasksJson = String(data: data, encoding: .utf8)
            }

            let adviceJson: String? = advice

            let screenshot = Screenshot(
                timestamp: frame.captureTime,
                appName: frame.appName,
                windowTitle: frame.windowTitle,
                imagePath: imagePath,
                isIndexed: false,
                focusStatus: focusStatus,
                extractedTasksJson: tasksJson,
                adviceJson: adviceJson
            )

            try await RewindDatabase.shared.insertScreenshot(screenshot)

        } catch {
            logError("RewindIndexer: Failed to process frame with metadata: \(error)")
        }
    }

    // MARK: - Background OCR Processing

    private func startOCRProcessing() {
        ocrTask?.cancel()
        ocrTask = Task {
            while !Task.isCancelled {
                await processOCRBatch()
                // Wait before next batch
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }
    }

    private func processOCRBatch() async {
        guard !isProcessingOCR else { return }
        isProcessingOCR = true
        defer { isProcessingOCR = false }

        do {
            // Get pending screenshots
            let pending = try await RewindDatabase.shared.getPendingOCRScreenshots(limit: 5)

            for screenshot in pending {
                guard !Task.isCancelled else { break }
                guard let id = screenshot.id else { continue }

                do {
                    // Load image data
                    let imageData = try await RewindStorage.shared.loadScreenshot(
                        relativePath: screenshot.imagePath
                    )

                    // Extract text with bounding boxes
                    let ocrResult = try await RewindOCRService.shared.extractTextWithBounds(from: imageData)

                    // Update database with full OCR result (including bounding boxes)
                    try await RewindDatabase.shared.updateOCRResult(id: id, ocrResult: ocrResult)

                    log("RewindIndexer: OCR completed for screenshot \(id), extracted \(ocrResult.fullText.count) characters, \(ocrResult.blocks.count) text blocks")

                } catch {
                    logError("RewindIndexer: OCR failed for screenshot \(id): \(error)")
                    // Mark as indexed anyway to prevent retrying forever
                    let emptyResult = OCRResult(fullText: "", blocks: [], processedAt: Date())
                    try? await RewindDatabase.shared.updateOCRResult(id: id, ocrResult: emptyResult)
                }
            }

        } catch {
            logError("RewindIndexer: Failed to get pending OCR screenshots: \(error)")
        }
    }

    // MARK: - Cleanup

    /// Run cleanup to remove old screenshots
    func runCleanup() async {
        let retentionDays = RewindSettings.shared.retentionDays

        do {
            // Get cutoff date
            let cutoffDate = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!

            // Delete from database and get image paths
            let imagePaths = try await RewindDatabase.shared.deleteScreenshotsOlderThan(cutoffDate)

            // Delete from storage
            try await RewindStorage.shared.deleteScreenshots(relativePaths: imagePaths)

            // Clean up empty directories
            try await RewindStorage.shared.cleanupEmptyDirectories()

            if !imagePaths.isEmpty {
                log("RewindIndexer: Cleaned up \(imagePaths.count) old screenshots")
            }

        } catch {
            logError("RewindIndexer: Cleanup failed: \(error)")
        }
    }

    /// Stop the indexer and cancel background tasks
    func stop() {
        ocrTask?.cancel()
        ocrTask = nil
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
