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
    let tags: [String]

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case priority
        case sourceApp = "source_app"
        case inferredDeadline = "inferred_deadline"
        case confidence
        case tags
    }

    /// Primary tag (first tag) for backward compatibility
    var primaryTag: String? {
        tags.first
    }

    /// Check if any tag should trigger agent execution
    var shouldTriggerAgent: Bool {
        let agentTags: Set<String> = ["feature", "bug", "code"]
        return tags.contains { agentTags.contains($0) }
    }

    /// Convert to dictionary for Flutter
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "title": title,
            "priority": priority.rawValue,
            "sourceApp": sourceApp,
            "confidence": confidence,
            "tags": tags.map { $0 },
            "category": primaryTag ?? "other"
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

// MARK: - Decision-Only Response (when search found close matches, model decides new vs duplicate)

/// Used when search results have close matches (similarity ≥ 0.5).
/// All fields required — no ambiguity.
struct TaskDecisionResult: Codable {
    let isNewTask: Bool
    let reason: String
    let contextSummary: String
    let currentActivity: String

    enum CodingKeys: String, CodingKey {
        case isNewTask = "is_new_task"
        case reason
        case contextSummary = "context_summary"
        case currentActivity = "current_activity"
    }
}

// MARK: - Extraction-Only Response (when clearly a new task, model extracts details)

/// Used when search results have no close matches, or after decision says is_new_task=true.
/// All fields required — no ambiguity.
struct TaskExtractionResponse: Codable {
    let title: String
    let description: String
    let priority: TaskPriority
    let tags: [String]
    let sourceApp: String
    let inferredDeadline: String
    let confidence: Double
    let contextSummary: String
    let currentActivity: String

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case priority
        case tags
        case sourceApp = "source_app"
        case inferredDeadline = "inferred_deadline"
        case confidence
        case contextSummary = "context_summary"
        case currentActivity = "current_activity"
    }

    /// Convert to TaskExtractionResult with embedded ExtractedTask
    func toExtractionResult() -> TaskExtractionResult {
        let task = ExtractedTask(
            title: title,
            description: description.isEmpty ? nil : description,
            priority: priority,
            sourceApp: sourceApp,
            inferredDeadline: inferredDeadline.isEmpty ? nil : inferredDeadline,
            confidence: confidence,
            tags: tags
        )
        return TaskExtractionResult(
            hasNewTask: true,
            task: task,
            contextSummary: contextSummary,
            currentActivity: currentActivity
        )
    }
}

// MARK: - Task Extraction Context (for single-stage pipeline)

/// Context injected into the extraction prompt for deduplication
struct TaskExtractionContext {
    let activeTasks: [(id: Int64, description: String, priority: String?)]
    let completedTasks: [(id: Int64, description: String)]
    let deletedTasks: [(id: Int64, description: String)]
    let goals: [Goal]
}

/// Result from vector/FTS search during tool-calling extraction
struct TaskSearchResult: Codable {
    let id: Int64
    let description: String
    let status: String          // "active", "completed", "deleted"
    let similarity: Double?     // cosine similarity (nil for FTS-only matches)
    let matchType: String       // "vector", "fts", "both"

    enum CodingKeys: String, CodingKey {
        case id, description, status, similarity
        case matchType = "match_type"
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
