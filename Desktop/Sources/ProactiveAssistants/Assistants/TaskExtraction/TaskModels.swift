import Foundation

// MARK: - Task Priority

enum TaskPriority: String, Codable {
    case high
    case medium
    case low
}

// MARK: - Extracted Task

/// Task category for classification
enum TaskClassification: String, Codable, CaseIterable {
    case personal
    case work
    case feature
    case bug
    case code
    case research
    case communication
    case finance
    case health
    case other

    /// Categories that should trigger Claude agent execution
    static let agentCategories: Set<TaskClassification> = [.feature, .bug, .code]

    /// Check if this category should trigger an agent
    var shouldTriggerAgent: Bool {
        Self.agentCategories.contains(self)
    }

    /// User-friendly display label
    var label: String {
        switch self {
        case .personal: return "Personal"
        case .work: return "Work"
        case .feature: return "Feature"
        case .bug: return "Bug"
        case .code: return "Code"
        case .research: return "Research"
        case .communication: return "Communication"
        case .finance: return "Finance"
        case .health: return "Health"
        case .other: return "Other"
        }
    }

    /// Icon name for the category
    var icon: String {
        switch self {
        case .personal: return "person.fill"
        case .work: return "briefcase.fill"
        case .feature: return "sparkles"
        case .bug: return "ladybug.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .research: return "magnifyingglass"
        case .communication: return "message.fill"
        case .finance: return "dollarsign.circle.fill"
        case .health: return "heart.fill"
        case .other: return "folder.fill"
        }
    }

    /// Color for the category
    var color: String {
        switch self {
        case .personal: return "#8B5CF6"  // Purple
        case .work: return "#3B82F6"      // Blue
        case .feature: return "#10B981"   // Green
        case .bug: return "#EF4444"       // Red
        case .code: return "#F59E0B"      // Amber
        case .research: return "#6366F1"  // Indigo
        case .communication: return "#EC4899" // Pink
        case .finance: return "#14B8A6"   // Teal
        case .health: return "#F43F5E"    // Rose
        case .other: return "#6B7280"     // Gray
        }
    }
}

struct ExtractedTask: Codable {
    let title: String
    let description: String?
    let priority: TaskPriority
    let sourceApp: String
    let inferredDeadline: String?
    let confidence: Double
    let category: TaskClassification

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case priority
        case sourceApp = "source_app"
        case inferredDeadline = "inferred_deadline"
        case confidence
        case category
    }

    /// Convert to dictionary for Flutter
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "title": title,
            "priority": priority.rawValue,
            "sourceApp": sourceApp,
            "confidence": confidence,
            "category": category.rawValue
        ]
        if let description = description {
            dict["description"] = description
        }
        if let deadline = inferredDeadline {
            dict["inferredDeadline"] = deadline
        }
        return dict
    }
}

// MARK: - Task Extraction Result

struct TaskExtractionResult: Codable, AssistantResult {
    let hasNewTask: Bool
    let task: ExtractedTask?
    let contextSummary: String
    let currentActivity: String

    enum CodingKeys: String, CodingKey {
        case hasNewTask = "has_new_task"
        case task
        case contextSummary = "context_summary"
        case currentActivity = "current_activity"
    }

    /// Convert to dictionary for Flutter
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "hasNewTask": hasNewTask,
            "contextSummary": contextSummary,
            "currentActivity": currentActivity
        ]
        if let task = task {
            dict["task"] = task.toDictionary()
        }
        return dict
    }
}

// MARK: - Task Event (for Flutter communication)

struct TaskEvent {
    let eventType: TaskEventType
    let task: ExtractedTask?
    let contextSummary: String?
    let timestamp: Date

    enum TaskEventType: String {
        case taskExtracted = "taskExtracted"
        case taskUpdated = "taskUpdated"
        case taskCompleted = "taskCompleted"
        case activityChanged = "activityChanged"
    }

    init(eventType: TaskEventType, result: TaskExtractionResult) {
        self.eventType = eventType
        self.task = result.task
        self.contextSummary = result.contextSummary
        self.timestamp = Date()
    }

    /// Convert to dictionary for Flutter EventChannel
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "eventType": eventType.rawValue,
            "contextSummary": contextSummary ?? "",
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ]
        if let task = task {
            dict["task"] = task.toDictionary()
        }
        return dict
    }
}
