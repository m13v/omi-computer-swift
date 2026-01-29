import Foundation
import GRDB

// MARK: - Screenshot Model

/// Represents a captured screenshot stored in the Rewind database
struct Screenshot: Codable, FetchableRecord, PersistableRecord, Identifiable {
    /// Database row ID (auto-generated)
    var id: Int64?

    /// When the screenshot was captured
    var timestamp: Date

    /// Name of the application that was active
    var appName: String

    /// Title of the window (if available)
    var windowTitle: String?

    /// Relative path to the JPEG image file
    var imagePath: String

    /// Extracted OCR text (nullable until indexed)
    var ocrText: String?

    /// Whether OCR has been completed
    var isIndexed: Bool

    /// Focus status at capture time ("focused" | "distracted" | nil)
    var focusStatus: String?

    /// JSON-encoded array of extracted tasks
    var extractedTasksJson: String?

    /// JSON-encoded advice object
    var adviceJson: String?

    static let databaseTableName = "screenshots"

    // MARK: - Initialization

    init(
        id: Int64? = nil,
        timestamp: Date = Date(),
        appName: String,
        windowTitle: String? = nil,
        imagePath: String,
        ocrText: String? = nil,
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
        self.ocrText = ocrText
        self.isIndexed = isIndexed
        self.focusStatus = focusStatus
        self.extractedTasksJson = extractedTasksJson
        self.adviceJson = adviceJson
    }

    // MARK: - Persistence Callbacks

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Search Result

/// A search result containing a screenshot and match information
struct ScreenshotSearchResult: Identifiable {
    let screenshot: Screenshot
    let matchedText: String?

    var id: Int64? { screenshot.id }
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

    private init() {
        // Load settings with defaults
        self.isEnabled = defaults.object(forKey: "rewindEnabled") as? Bool ?? true
        self.retentionDays = defaults.object(forKey: "rewindRetentionDays") as? Int ?? 7
        self.captureInterval = defaults.object(forKey: "rewindCaptureInterval") as? Double ?? 1.0
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
