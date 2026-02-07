import Foundation

/// Manages Task Extraction Assistant-specific settings stored in UserDefaults
@MainActor
class TaskAssistantSettings {
    static let shared = TaskAssistantSettings()

    // MARK: - UserDefaults Keys

    private let enabledKey = "taskAssistantEnabled"
    private let analysisPromptKey = "taskAnalysisPrompt"
    private let extractionIntervalKey = "taskExtractionInterval"
    private let minConfidenceKey = "taskMinConfidence"
    private let excludedAppsKey = "taskExcludedApps"

    // MARK: - Built-in Skip List

    /// Apps that never contain useful content for proactive assistants — utility/media/system apps + our own app.
    /// Shared across Task, Advice, and Memory assistants.
    static let builtInExcludedApps: Set<String> = [
        "Omi",
        "Omi Beta",
        "Omi Dev",
        "Finder",
        "System Preferences",
        "System Settings",
        "Music",
        "Spotify",
        "Photos",
        "Preview",
        "Calculator",
        "QuickTime Player",
        "Activity Monitor",
        "Disk Utility",
        "Font Book",
        "Archive Utility",
        "Installer",
        "Screenshot",
    ]

    // MARK: - Default Values

    private let defaultEnabled = true
    private let defaultExtractionInterval: TimeInterval = 600.0 // 10 minutes
    private let defaultMinConfidence: Double = 0.75

    /// Default system prompt for task extraction
    static let defaultAnalysisPrompt = """
        You are a request detector. Your ONLY job: find an unaddressed request or question directed at the user from another person or AI assistant.

        CORE QUESTION: "Is someone asking or telling the user to do something that the user hasn't acted on yet?"
        - If YES → extract it. If NO → set has_new_task to false.

        DEDUPLICATION: You will receive a list of PREVIOUSLY EXTRACTED TASKS.
        - Use semantic comparison ("Review PR #123" ≈ "Check pull request 123")
        - If the request is already covered, set has_new_task to false

        WHO COUNTS AS "SOMEONE":
        - A coworker in Slack, Teams, Discord, email
        - A friend/family member in iMessage, WhatsApp, Telegram, Messenger
        - An AI assistant (ChatGPT, Claude, Copilot) suggesting the user do something
        - A calendar event with preparation needed
        - The user's own explicit reminder ("Remind me to…", "TODO: …", "Don't forget…")

        CHAT DIRECTION (critical for messengers):
        - LEFT / incoming bubbles = from another person → may contain a request
        - RIGHT / outgoing bubbles = from the user → already handled, skip
        - If the last message in the thread is the user's reply, the request is addressed → skip

        REQUEST PATTERNS TO LOOK FOR:
        - "Can you…", "Could you…", "Please…", "Don't forget to…", "Make sure you…"
        - "Remind me to…", "Remember to…", "TODO:", "FIXME:"
        - Questions expecting an answer: "What's the status of…?", "When will you…?"
        - Assigned items: "@user", "assigned to you", review requests

        ALWAYS SKIP — these are NOT requests from people:
        - Terminal output, build logs, compiler warnings, pip/npm upgrade notices
        - Code the user is actively writing or editing
        - Project management boards (Jira, Linear, Trello) — already tracked elsewhere
        - Notification badges without visible message content
        - System UI, settings panels, media players, file browsers
        - Anything the user is clearly in the middle of doing right now

        FORGETTABILITY CHECK:
        Ask: "Will the user forget this request after switching away from this window?"
        - YES → extract (that's why we exist)
        - NO (it's their active focus, or tracked in a tool) → skip

        FORMAT (when extracting):
        - title: Short, verb-first, ≤100 chars. Include WHO and WHAT. ("Reply to Sarah about Q4 report")
        - priority: "high" (urgent/today), "medium" (this week), "low" (no deadline)
        - confidence: 0.9+ explicit request, 0.7-0.9 clear implicit, 0.5-0.7 ambiguous
        - Put deadline info in inferred_deadline, not in the title

        OUTPUT:
        - has_new_task: true/false
        - task: the extracted request (only if has_new_task is true)
        - context_summary: brief summary of what user is looking at
        - current_activity: what the user is actively doing
        """

    private init() {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            enabledKey: defaultEnabled,
            extractionIntervalKey: defaultExtractionInterval,
            minConfidenceKey: defaultMinConfidence,
        ])
    }

    // MARK: - Properties

    /// Whether the Task Extraction Assistant is enabled
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// The system prompt used for AI task extraction
    var analysisPrompt: String {
        get {
            let value = UserDefaults.standard.string(forKey: analysisPromptKey)
            return value ?? TaskAssistantSettings.defaultAnalysisPrompt
        }
        set {
            let isCustom = newValue != TaskAssistantSettings.defaultAnalysisPrompt
            UserDefaults.standard.set(newValue, forKey: analysisPromptKey)
            let previewLength = min(newValue.count, 50)
            let preview = String(newValue.prefix(previewLength)) + (newValue.count > 50 ? "..." : "")
            log("Task analysis prompt updated (\(newValue.count) chars, custom: \(isCustom)): \(preview)")
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Interval between task extraction analyses in seconds
    var extractionInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: extractionIntervalKey)
            return value > 0 ? value : defaultExtractionInterval
        }
        set {
            UserDefaults.standard.set(newValue, forKey: extractionIntervalKey)
            log("Task extraction interval updated to \(newValue) seconds")
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Minimum confidence threshold for reporting tasks
    var minConfidence: Double {
        get {
            let value = UserDefaults.standard.double(forKey: minConfidenceKey)
            return value > 0 ? value : defaultMinConfidence
        }
        set {
            UserDefaults.standard.set(newValue, forKey: minConfidenceKey)
            log("Task min confidence threshold updated to \(newValue)")
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Apps excluded from task extraction (screenshots still captured for other features)
    var excludedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: excludedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: excludedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Check if an app is excluded from task extraction (built-in list + user's custom list)
    func isAppExcluded(_ appName: String) -> Bool {
        TaskAssistantSettings.builtInExcludedApps.contains(appName) || excludedApps.contains(appName)
    }

    /// Add an app to the task extraction exclusion list
    func excludeApp(_ appName: String) {
        var apps = excludedApps
        apps.insert(appName)
        excludedApps = apps
        log("Task: Excluded app '\(appName)' from task extraction")
    }

    /// Remove an app from the task extraction exclusion list
    func includeApp(_ appName: String) {
        var apps = excludedApps
        apps.remove(appName)
        excludedApps = apps
        log("Task: Included app '\(appName)' for task extraction")
    }

    /// Reset only the analysis prompt to default
    func resetPromptToDefault() {
        UserDefaults.standard.removeObject(forKey: analysisPromptKey)
        log("Task analysis prompt reset to default")
        NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
    }

    /// Reset all Task Assistant settings to defaults
    func resetToDefaults() {
        isEnabled = defaultEnabled
        extractionInterval = defaultExtractionInterval
        minConfidence = defaultMinConfidence
        excludedApps = []
        resetPromptToDefault()
    }
}
