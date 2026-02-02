import AppKit
import AVFoundation
import Foundation

/// File storage manager for Rewind screenshots
actor RewindStorage {
    static let shared = RewindStorage()

    private let fileManager = FileManager.default
    private var screenshotsDirectory: URL?
    private var videosDirectory: URL?

    // Frame extraction cache
    private var frameCache = NSCache<NSString, NSImage>()

    // MARK: - Initialization

    private init() {
        // Configure cache limits
        frameCache.countLimit = 100 // Max 100 frames in cache
        frameCache.totalCostLimit = 100 * 1024 * 1024 // ~100MB
    }

    /// Initialize the storage directories
    func initialize() async throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omiDir = appSupport.appendingPathComponent("Omi", isDirectory: true)

        // Screenshots directory (legacy JPEG storage)
        screenshotsDirectory = omiDir.appendingPathComponent("Screenshots", isDirectory: true)

        // Videos directory (new H.265 chunk storage)
        videosDirectory = omiDir.appendingPathComponent("Videos", isDirectory: true)

        guard let screenshotsDirectory = screenshotsDirectory,
              let videosDirectory = videosDirectory
        else {
            throw RewindError.storageError("Failed to create storage directory paths")
        }

        try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

        // Initialize video encoder with videos directory
        try await VideoChunkEncoder.shared.initialize(videosDirectory: videosDirectory)

        log("RewindStorage: Initialized at \(omiDir.path)")
    }

    /// Get the videos directory URL for external use
    func getVideosDirectory() -> URL? {
        return videosDirectory
    }

    // MARK: - Save Screenshot

    /// Save JPEG data to disk and return the relative path
    func saveScreenshot(jpegData: Data, timestamp: Date) async throws -> String {
        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Storage not initialized")
        }

        // Create day subdirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayString = dateFormatter.string(from: timestamp)

        let dayDirectory = screenshotsDirectory.appendingPathComponent(dayString, isDirectory: true)
        try fileManager.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        // Create filename with timestamp
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "HHmmss_SSS"
        let timeString = timestampFormatter.string(from: timestamp)

        let filename = "screenshot_\(timeString).jpg"
        let relativePath = "\(dayString)/\(filename)"
        let fullPath = screenshotsDirectory.appendingPathComponent(relativePath)

        // Write the file
        try jpegData.write(to: fullPath)

        return relativePath
    }

    // MARK: - Load Screenshot

    /// Load image data from a relative path
    func loadScreenshot(relativePath: String) async throws -> Data {
        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Storage not initialized")
        }

        let fullPath = screenshotsDirectory.appendingPathComponent(relativePath)

        guard fileManager.fileExists(atPath: fullPath.path) else {
            throw RewindError.screenshotNotFound
        }

        return try Data(contentsOf: fullPath)
    }

    /// Get the full URL for a screenshot
    func getScreenshotURL(relativePath: String) async -> URL? {
        guard let screenshotsDirectory = screenshotsDirectory else {
            return nil
        }

        let fullPath = screenshotsDirectory.appendingPathComponent(relativePath)

        guard fileManager.fileExists(atPath: fullPath.path) else {
            return nil
        }

        return fullPath
    }

    /// Load screenshot as NSImage (legacy JPEG path)
    func loadScreenshotImage(relativePath: String) async throws -> NSImage {
        let data = try await loadScreenshot(relativePath: relativePath)
        guard let image = NSImage(data: data) else {
            throw RewindError.invalidImage
        }
        return image
    }

    // MARK: - Video Frame Loading

    /// Load a frame from a video chunk using ffmpeg (works with fragmented MP4)
    func loadVideoFrame(videoPath: String, frameOffset: Int) async throws -> NSImage {
        guard let videosDirectory = videosDirectory else {
            throw RewindError.storageError("Videos directory not initialized")
        }

        // Check cache first
        let cacheKey = "\(videoPath):\(frameOffset)" as NSString
        if let cached = frameCache.object(forKey: cacheKey) {
            return cached
        }

        let fullPath = videosDirectory.appendingPathComponent(videoPath)

        guard fileManager.fileExists(atPath: fullPath.path) else {
            throw RewindError.screenshotNotFound
        }

        // Use ffmpeg to extract frame (works with fragmented MP4)
        let image = try await extractFrameWithFFmpeg(from: fullPath.path, frameOffset: frameOffset)

        // Cache for reuse (estimate ~4MB per frame for cost)
        frameCache.setObject(image, forKey: cacheKey, cost: 4 * 1024 * 1024)

        return image
    }

    /// Extract a frame from video using ffmpeg
    private func extractFrameWithFFmpeg(from videoPath: String, frameOffset: Int) async throws -> NSImage {
        let ffmpegPath = findFFmpegPath()

        // Calculate time offset (1 FPS, so frame N is at N seconds)
        let timeOffset = Double(frameOffset)

        // Create a temporary file for the output
        let tempDir = FileManager.default.temporaryDirectory
        let outputPath = tempDir.appendingPathComponent("frame_\(UUID().uuidString).jpg")

        // Build ffmpeg command to extract single frame
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-ss", String(format: "%.3f", timeOffset),
            "-i", videoPath,
            "-vframes", "1",
            "-f", "image2",
            "-c:v", "mjpeg",
            "-q:v", "2", // High quality JPEG
            "-y", // Overwrite
            outputPath.path
        ]

        // Capture stderr for error handling
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw RewindError.storageError("Failed to run ffmpeg: \(error.localizedDescription)")
        }

        if process.terminationStatus != 0 {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrString = String(data: stderrData, encoding: .utf8) ?? "unknown error"
            throw RewindError.storageError("FFmpeg failed: \(stderrString)")
        }

        // Load the extracted frame
        guard let imageData = try? Data(contentsOf: outputPath),
              let image = NSImage(data: imageData)
        else {
            throw RewindError.storageError("Failed to load extracted frame")
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: outputPath)

        return image
    }

    /// Find ffmpeg executable path
    private func findFFmpegPath() -> String {
        let possiblePaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            Bundle.main.path(forResource: "ffmpeg", ofType: nil),
        ].compactMap { $0 }

        for path in possiblePaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return "ffmpeg"
    }

    /// Unified loading interface - loads from either JPEG or video storage
    func loadScreenshotImage(for screenshot: Screenshot) async throws -> NSImage {
        if screenshot.usesVideoStorage,
           let videoPath = screenshot.videoChunkPath,
           let offset = screenshot.frameOffset
        {
            return try await loadVideoFrame(videoPath: videoPath, frameOffset: offset)
        } else if let imagePath = screenshot.imagePath {
            return try await loadScreenshotImage(relativePath: imagePath)
        } else {
            throw RewindError.screenshotNotFound
        }
    }

    /// Get raw image data for a screenshot (for OCR processing)
    func loadScreenshotData(for screenshot: Screenshot) async throws -> Data {
        if screenshot.usesVideoStorage,
           let videoPath = screenshot.videoChunkPath,
           let offset = screenshot.frameOffset
        {
            // Load frame and convert to JPEG data
            let image = try await loadVideoFrame(videoPath: videoPath, frameOffset: offset)
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else {
                throw RewindError.invalidImage
            }
            return jpegData
        } else if let imagePath = screenshot.imagePath {
            return try await loadScreenshot(relativePath: imagePath)
        } else {
            throw RewindError.screenshotNotFound
        }
    }

    /// Clear the frame cache
    func clearCache() {
        frameCache.removeAllObjects()
    }

    // MARK: - Delete Screenshot

    /// Delete a screenshot file
    func deleteScreenshot(relativePath: String) async throws {
        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Storage not initialized")
        }

        let fullPath = screenshotsDirectory.appendingPathComponent(relativePath)

        if fileManager.fileExists(atPath: fullPath.path) {
            try fileManager.removeItem(at: fullPath)
        }
    }

    /// Delete multiple screenshots
    func deleteScreenshots(relativePaths: [String]) async throws {
        for path in relativePaths {
            try await deleteScreenshot(relativePath: path)
        }
    }

    // MARK: - Video Chunk Deletion

    /// Delete a video chunk file
    func deleteVideoChunk(relativePath: String) async throws {
        guard let videosDirectory = videosDirectory else {
            throw RewindError.storageError("Videos directory not initialized")
        }

        let fullPath = videosDirectory.appendingPathComponent(relativePath)

        // Invalidate cache entries for this chunk (we can't iterate NSCache, so just clear relevant entries by rebuilding)
        // The cache will naturally evict old entries

        if fileManager.fileExists(atPath: fullPath.path) {
            try fileManager.removeItem(at: fullPath)
            log("RewindStorage: Deleted video chunk \(relativePath)")
        }
    }

    /// Delete multiple video chunks
    func deleteVideoChunks(relativePaths: [String]) async throws {
        for path in relativePaths {
            try await deleteVideoChunk(relativePath: path)
        }
    }

    // MARK: - Cleanup

    /// Delete empty day directories in both Screenshots and Videos folders
    func cleanupEmptyDirectories() async throws {
        // Clean up Screenshots directory
        if let screenshotsDirectory = screenshotsDirectory {
            try cleanupEmptySubdirectories(in: screenshotsDirectory)
        }

        // Clean up Videos directory
        if let videosDirectory = videosDirectory {
            try cleanupEmptySubdirectories(in: videosDirectory)
        }
    }

    private func cleanupEmptySubdirectories(in directory: URL) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )

        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                let subContents = try fileManager.contentsOfDirectory(atPath: url.path)
                if subContents.isEmpty {
                    try fileManager.removeItem(at: url)
                    log("RewindStorage: Removed empty directory \(url.lastPathComponent)")
                }
            }
        }
    }

    /// Delete screenshots older than the specified number of days
    func deleteOldScreenshots(olderThanDays days: Int) async throws -> Int {
        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Storage not initialized")
        }

        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let cutoffString = dateFormatter.string(from: cutoffDate)

        var deletedCount = 0

        let contents = try fileManager.contentsOfDirectory(
            at: screenshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )

        for url in contents {
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                let dirName = url.lastPathComponent
                // Compare directory name (yyyy-MM-dd) with cutoff
                if dirName < cutoffString {
                    let subContents = try fileManager.contentsOfDirectory(atPath: url.path)
                    deletedCount += subContents.count
                    try fileManager.removeItem(at: url)
                    log("RewindStorage: Deleted old directory \(dirName) with \(subContents.count) files")
                }
            }
        }

        return deletedCount
    }

    // MARK: - Storage Stats

    /// Get total storage size in bytes (both Screenshots and Videos)
    func getTotalStorageSize() async throws -> Int64 {
        var totalSize: Int64 = 0

        if let screenshotsDirectory = screenshotsDirectory {
            totalSize += try calculateDirectorySize(at: screenshotsDirectory)
        }

        if let videosDirectory = videosDirectory {
            totalSize += try calculateDirectorySize(at: videosDirectory)
        }

        return totalSize
    }

    private func calculateDirectorySize(at url: URL) throws -> Int64 {
        var totalSize: Int64 = 0

        let resourceKeys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: .skipsHiddenFiles
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: resourceKeys)
            if resourceValues.isDirectory == false {
                totalSize += Int64(resourceValues.fileSize ?? 0)
            }
        }

        return totalSize
    }

    /// Format bytes as human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
