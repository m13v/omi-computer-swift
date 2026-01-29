import Foundation
import AppKit

/// File storage manager for Rewind screenshots
actor RewindStorage {
    static let shared = RewindStorage()

    private let fileManager = FileManager.default
    private var screenshotsDirectory: URL?

    // MARK: - Initialization

    private init() {}

    /// Initialize the storage directory
    func initialize() async throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let omiDir = appSupport.appendingPathComponent("Omi", isDirectory: true)
        screenshotsDirectory = omiDir.appendingPathComponent("Screenshots", isDirectory: true)

        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Failed to create screenshots directory path")
        }

        try fileManager.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
        log("RewindStorage: Initialized at \(screenshotsDirectory.path)")
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

    /// Load screenshot as NSImage
    func loadScreenshotImage(relativePath: String) async throws -> NSImage {
        let data = try await loadScreenshot(relativePath: relativePath)
        guard let image = NSImage(data: data) else {
            throw RewindError.invalidImage
        }
        return image
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

    // MARK: - Cleanup

    /// Delete empty day directories
    func cleanupEmptyDirectories() async throws {
        guard let screenshotsDirectory = screenshotsDirectory else {
            return
        }

        let contents = try fileManager.contentsOfDirectory(
            at: screenshotsDirectory,
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

    /// Get total storage size in bytes
    func getTotalStorageSize() async throws -> Int64 {
        guard let screenshotsDirectory = screenshotsDirectory else {
            throw RewindError.storageError("Storage not initialized")
        }

        return try calculateDirectorySize(at: screenshotsDirectory)
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
