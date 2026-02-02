import Foundation
import GRDB

// MARK: - Screenshot Model

/// Represents a captured screenshot stored in the Rewind database
struct Screenshot: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    /// Database row ID (auto-generated)
    var id: Int64?

    /// When the screenshot was captured
    var timestamp: Date

    /// Name of the application that was active
    var appName: String

    /// Title of the window (if available)
    var windowTitle: String?

    /// Relative path to the JPEG image file (legacy, nil for video storage)
    var imagePath: String?

    /// Relative path to the video chunk file (new video storage)
    var videoChunkPath: String?

    /// Frame index within the video chunk
    var frameOffset: Int?

    /// Extracted OCR text (nullable until indexed)
    var ocrText: String?

    /// JSON-encoded OCR data with bounding boxes
    var ocrDataJson: String?

    /// Whether OCR has been completed
    var isIndexed: Bool

    /// Focus status at capture time ("focused" | "distracted" | nil)
    var focusStatus: String?

    /// JSON-encoded array of extracted tasks
    var extractedTasksJson: String?

    /// JSON-encoded advice object
    var adviceJson: String?

    static let databaseTableName = "screenshots"

    // MARK: - Storage Type

    /// Whether this screenshot uses video chunk storage (vs legacy JPEG)
    var usesVideoStorage: Bool {
        videoChunkPath != nil && frameOffset != nil
    }

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        appName: String,
        windowTitle: String? = nil,
        imagePath: String? = nil,
        videoChunkPath: String? = nil,
        frameOffset: Int? = nil,
        ocrText: String? = nil,
        ocrDataJson: String? = nil,
        isIndexed: Bool = false,
        focusStatus: String? = nil,
        extractedTasksJson: String? = nil,
        adviceJson: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.windowTitle = windowTitle
        self.imagePath = imagePath
        self.videoChunkPath = videoChunkPath
        self.frameOffset = frameOffset
        self.ocrText = ocrText
        self.ocrDataJson = ocrDataJson
        self.isIndexed = isIndexed
        self.focusStatus = focusStatus
        self.extractedTasksJson = extractedTasksJson
        self.adviceJson = adviceJson
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - OCR Data Access

    /// Decode the OCR result with bounding boxes
    var ocrResult: OCRResult? {
        guard let jsonString = ocrDataJson,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(OCRResult.self, from: data)
    }

    /// Get text blocks that match a search query
    func matchingBlocks(for query: String) -> [OCRTextBlock] {
        return ocrResult?.blocksContaining(query) ?? []
    }

    /// Get a context snippet for a search query
    func contextSnippet(for query: String) -> String? {
        return ocrResult?.contextSnippet(for: query)
    }
}

// MARK: - Search Result

/// A search result containing a screenshot and match information
struct ScreenshotSearchResult: Identifiable, Equatable {
    let screenshot: Screenshot
    let matchedText: String?
    let contextSnippet: String?
    let matchingBlocks: [OCRTextBlock]

    var id: Int64? { screenshot.id }

    init(screenshot: Screenshot, query: String? = nil) {
        self.screenshot = screenshot
        self.matchedText = query

        if let query = query, !query.isEmpty {
            self.contextSnippet = screenshot.contextSnippet(for: query)
            self.matchingBlocks = screenshot.matchingBlocks(for: query)
        } else {
            self.contextSnippet = nil
            self.matchingBlocks = []
        }
    }
}

// MARK: - Rewind Error Types

enum RewindError: LocalizedError {
    case databaseNotInitialized
    case invalidImage
    case storageError(String)
    case ocrFailed(String)
    case screenshotNotFound

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "Rewind database is not initialized"
        case .invalidImage:
            return "Invalid image data"
        case .storageError(let message):
            return "Storage error: \(message)"
        case .ocrFailed(let message):
            return "OCR failed: \(message)"
        case .screenshotNotFound:
            return "Screenshot not found"
        }
    }
}

// MARK: - Rewind Settings

/// Settings for the Rewind feature
class RewindSettings: ObservableObject {
    static let shared = RewindSettings()

    private let defaults = UserDefaults.standard

    /// Default apps that should be excluded from screen capture for privacy
    static let defaultExcludedApps: Set<String> = [
        "Passwords",           // macOS Passwords app
        "1Password",           // 1Password (various versions)
        "1Password 7",
        "Bitwarden",           // Bitwarden
        "LastPass",            // LastPass
        "Dashlane",            // Dashlane
        "Keeper",              // Keeper Password Manager
        "Enpass",              // Enpass
        "KeePassXC",           // KeePassXC
        "Keychain Access",     // macOS Keychain Access
    ]

    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "rewindEnabled")
        }
    }

    @Published var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: "rewindRetentionDays")
        }
    }

    @Published var captureInterval: Double {
        didSet {
            defaults.set(captureInterval, forKey: "rewindCaptureInterval")
        }
    }

    @Published var excludedApps: Set<String> {
        didSet {
            let array = Array(excludedApps)
            defaults.set(array, forKey: "rewindExcludedApps")
        }
    }

    private init() {
        // Load settings with defaults
        self.isEnabled = defaults.object(forKey: "rewindEnabled") as? Bool ?? true
        self.retentionDays = defaults.object(forKey: "rewindRetentionDays") as? Int ?? 7
        self.captureInterval = defaults.object(forKey: "rewindCaptureInterval") as? Double ?? 1.0

        // Load excluded apps, defaulting to the default list if not set
        if let savedApps = defaults.array(forKey: "rewindExcludedApps") as? [String] {
            self.excludedApps = Set(savedApps)
        } else {
            self.excludedApps = Self.defaultExcludedApps
        }
    }

    /// Check if an app is excluded from screen capture
    func isAppExcluded(_ appName: String) -> Bool {
        excludedApps.contains(appName)
    }

    /// Add an app to the exclusion list
    func excludeApp(_ appName: String) {
        excludedApps.insert(appName)
    }

    /// Remove an app from the exclusion list
    func includeApp(_ appName: String) {
        excludedApps.remove(appName)
    }

    /// Reset excluded apps to defaults
    func resetToDefaults() {
        excludedApps = Self.defaultExcludedApps
    }
}

// MARK: - Date Formatting Extensions

extension Screenshot {
    /// Formatted date string for display
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    /// Time-only string for timeline display
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    /// Day string for grouping
    var dayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: timestamp)
    }
}
