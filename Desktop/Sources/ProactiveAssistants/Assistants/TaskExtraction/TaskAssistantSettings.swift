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
    private let allowedAppsKey = "taskAllowedApps"
    private let disabledHeuristicsKey = "taskDisabledBrowserHeuristics"

    // MARK: - Built-in Allowed Apps (Whitelist)

    /// Apps that are allowed for task extraction by default — communication, browser, and productivity apps
    /// where actionable requests are most likely to appear.
    static let builtInAllowedApps: Set<String> = [
        "Telegram",
        "\u{200E}WhatsApp",  // WhatsApp uses a hidden LTR mark prefix
        "WhatsApp",
        "Messages",
        "Slack",
        "Discord",
        "zoom.us",
        "Google Chrome",
        "Arc",
        "Safari",
        "Firefox",
        "Microsoft Edge",
        "Brave Browser",
        "Opera",
        "Notes",
        "Superhuman",
    ]

    // MARK: - Browser Apps

    /// Apps identified as browsers — these get additional window-title filtering via heuristics
    static let browserApps: Set<String> = [
        "Google Chrome",
        "Arc",
        "Safari",
        "Firefox",
        "Microsoft Edge",
        "Brave Browser",
        "Opera",
    ]

    /// Check if an app is a browser (subject to window title heuristics)
    static func isBrowser(_ appName: String) -> Bool {
        browserApps.contains(appName)
    }

    // MARK: - Browser Window Heuristics

    /// A heuristic rule for filtering browser windows by title
    struct BrowserHeuristic: Identifiable {
        let id: String
        let name: String
        let description: String
        let patterns: [String]  // case-insensitive substrings to match in window title
        let defaultEnabled: Bool
    }

    /// All built-in browser window heuristics
    static let builtInHeuristics: [BrowserHeuristic] = [
        BrowserHeuristic(
            id: "email",
            name: "Email",
            description: "Gmail, Outlook, Yahoo Mail, ProtonMail",
            patterns: ["Gmail", "Outlook", "Yahoo Mail", "ProtonMail", "Superhuman", "Fastmail", "Mail -"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "messaging",
            name: "Messaging",
            description: "Slack, Discord, WhatsApp, Telegram, Messenger web apps",
            patterns: ["Slack", "Discord", "WhatsApp", "Telegram", "Messenger", "Signal"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "project_mgmt",
            name: "Project Management",
            description: "Jira, Linear, Trello, Asana, Notion, ClickUp",
            patterns: ["Jira", "Linear", "Trello", "Asana", "Notion", "Monday", "ClickUp", "Basecamp"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "calendar",
            name: "Calendar",
            description: "Google Calendar, Outlook Calendar, Calendly",
            patterns: ["Google Calendar", "Outlook Calendar", "Cal.com", "Calendly"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "github",
            name: "GitHub",
            description: "Issues, pull requests, notifications",
            patterns: ["GitHub", "github.com"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "google_docs",
            name: "Google Docs/Sheets/Slides",
            description: "Collaborative Google Workspace documents",
            patterns: ["Google Docs", "Google Sheets", "Google Slides"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "finance",
            name: "Finance",
            description: "Stripe, PayPal, invoices, billing",
            patterns: ["Stripe", "PayPal", "Invoice", "Billing", "QuickBooks"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "forms",
            name: "Forms & Signing",
            description: "Google Forms, Typeform, DocuSign",
            patterns: ["Google Forms", "Typeform", "DocuSign"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "social",
            name: "Social Media",
            description: "Twitter/X, LinkedIn, Reddit",
            patterns: [" / X", "Twitter", "LinkedIn", "Reddit"],
            defaultEnabled: false
        ),
        BrowserHeuristic(
            id: "ci_cd",
            name: "CI/CD & Monitoring",
            description: "Vercel, Netlify, Sentry, Datadog",
            patterns: ["Vercel", "Netlify", "Railway", "Sentry", "Datadog", "PagerDuty"],
            defaultEnabled: false
        ),
        BrowserHeuristic(
            id: "cloud",
            name: "Cloud Consoles",
            description: "GCP, AWS, Azure, Firebase",
            patterns: ["Google Cloud", "AWS", "Azure", "Firebase"],
            defaultEnabled: false
        ),
        BrowserHeuristic(
            id: "design",
            name: "Design Tools",
            description: "Figma, Canva, Miro",
            patterns: ["Figma", "Canva", "Miro"],
            defaultEnabled: false
        ),
        BrowserHeuristic(
            id: "action_keywords",
            name: "Action Keywords",
            description: "Window titles containing todo, task, review, assign, request, ticket",
            patterns: ["todo", "task", "assign", "review", "approve", "request", "ticket"],
            defaultEnabled: true
        ),
        BrowserHeuristic(
            id: "inbox_notifications",
            name: "Inbox & Notifications",
            description: "Window titles containing inbox, unread, notification, pending",
            patterns: ["inbox", "unread", "notification", "pending"],
            defaultEnabled: true
        ),
    ]

    // MARK: - Built-in Exclude List (used by other assistants: Advice, Focus, Memory)

    /// Apps that never contain useful content for proactive assistants — utility/media/system apps + our own app.
    /// Shared across Advice, Focus, and Memory assistants (Task extraction uses whitelist instead).
    static let builtInExcludedApps: Set<String> = [
        "Omi",
        "Omi Beta",
        "Omi Dev",
        "Omi Computer",
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

    /// Default system prompt for task extraction (loop-based with tool calling)
    static let defaultAnalysisPrompt = """
        You are a request detector. Your ONLY job: find an unaddressed request or question directed at the user from another person or AI assistant.

        MANDATORY WORKFLOW:
        1. Analyze the screenshot to identify any potential request
        2. If clearly no request (code editor, terminal, settings, media, dashboards) → call no_task_found immediately
        3. If potential request visible → search for duplicates using search_similar and/or search_keywords
        4. You may search multiple times with different queries to be thorough
        5. Based on results → call extract_task (new task) or reject_task (duplicate/completed/rejected)

        AVAILABLE TOOLS:
        - search_similar(query): Find semantically similar existing tasks (vector similarity)
        - search_keywords(query): Find tasks matching specific keywords (keyword search)
        - extract_task(...): Extract a new task (call ONLY after searching)
        - reject_task(reason, ...): Reject extraction — task is duplicate, completed, or already tracked
        - no_task_found(...): No actionable request on screen (~90% of screenshots)

        SEARCH RULES:
        - You MUST search at least once before calling extract_task
        - You may call search_similar and search_keywords with different queries
        - Similarity > 0.8 + status "active" → duplicate → reject_task
        - Status "completed" → already done → reject_task
        - Status "deleted" → user rejected → reject_task

        CORE QUESTION: "Is someone asking or telling the user to do something that the user hasn't acted on yet?"
        - If YES → search then extract. If NO → call no_task_found.

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

        SPECIFICITY REQUIREMENT:
        If you cannot identify a specific person, project, or deliverable, the task is too vague — skip it.

        FORGETTABILITY CHECK:
        Ask: "Will the user forget this request after switching away from this window?"
        - YES → extract (that's why we exist)
        - NO (it's their active focus, or tracked in a tool) → skip

        FORMAT (when calling extract_task):
        - title: Short, verb-first, ≤15 words. Include WHO and WHAT. ("Reply to Sarah about Q4 report")
        - priority: "high" (urgent/today), "medium" (this week), "low" (no deadline)
        - confidence: 0.9+ explicit request, 0.7-0.9 clear implicit, 0.5-0.7 ambiguous
        - Put deadline info in inferred_deadline, not in the title

        SOURCE CLASSIFICATION (mandatory for every extracted task):
        Classify each task's origin with source_category + source_subcategory.
        Categories and their subcategories:
        - direct_request: Someone explicitly asked the user to do something.
          → message (chat/email message), meeting (verbal request in meeting), mention (@mention/tag)
        - self_generated: User created this for themselves.
          → idea (user's own idea/note), reminder (explicit "remind me"), goal_subtask (part of a larger goal)
        - calendar_driven: Triggered by a calendar event or deadline.
          → event_prep (prepare for upcoming event), recurring (repeating task), deadline (approaching due date)
        - reactive: Response to something that happened.
          → error (build error/crash), notification (system/app notification), observation (something noticed on screen)
        - external_system: Comes from a project tool or automated system.
          → project_tool (Jira/Linear/Trello), alert (monitoring/CI alert), documentation (doc update needed)
        - other: None of the above. → other

        Examples:
        - Slack message "Can you review my PR?" → direct_request / message
        - User's own TODO comment in code → self_generated / idea
        - Calendar event "Team standup" in 30 min → calendar_driven / event_prep
        - Build failure notification → reactive / error
        - Linear ticket assigned to user → external_system / project_tool
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

    /// Apps allowed for task extraction (user-added, on top of built-in list)
    var allowedApps: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: allowedAppsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: allowedAppsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// IDs of heuristics the user has explicitly disabled (stored in UserDefaults)
    var disabledHeuristicIds: Set<String> {
        get {
            if let saved = UserDefaults.standard.array(forKey: disabledHeuristicsKey) as? [String] {
                return Set(saved)
            }
            return []
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: disabledHeuristicsKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Check if a heuristic is enabled (respects both default state and user overrides)
    func isHeuristicEnabled(_ heuristic: BrowserHeuristic) -> Bool {
        let disabled = disabledHeuristicIds
        if disabled.contains(heuristic.id) { return false }
        // If user hasn't explicitly disabled it, use the default
        return heuristic.defaultEnabled || enabledHeuristicIds.contains(heuristic.id)
    }

    /// IDs of heuristics the user has explicitly enabled (for non-default ones)
    private var enabledHeuristicIds: Set<String> {
        if let saved = UserDefaults.standard.array(forKey: "taskEnabledBrowserHeuristics") as? [String] {
            return Set(saved)
        }
        return []
    }

    /// Toggle a heuristic on or off
    func setHeuristicEnabled(_ id: String, enabled: Bool) {
        var disabled = disabledHeuristicIds
        var explicitlyEnabled = enabledHeuristicIds

        if enabled {
            disabled.remove(id)
            explicitlyEnabled.insert(id)
        } else {
            disabled.insert(id)
            explicitlyEnabled.remove(id)
        }

        disabledHeuristicIds = disabled
        UserDefaults.standard.set(Array(explicitlyEnabled), forKey: "taskEnabledBrowserHeuristics")
        log("Task: Browser heuristic '\(id)' set to \(enabled ? "enabled" : "disabled")")
    }

    /// Check if an app is allowed for task extraction (built-in whitelist + user's custom whitelist)
    func isAppAllowed(_ appName: String) -> Bool {
        TaskAssistantSettings.builtInAllowedApps.contains(appName) || allowedApps.contains(appName)
    }

    /// For browser apps, check if the window title matches any enabled heuristic.
    /// Non-browser apps always pass this check.
    func isWindowAllowed(appName: String, windowTitle: String?) -> Bool {
        guard TaskAssistantSettings.isBrowser(appName) else { return true }
        guard let title = windowTitle, !title.isEmpty else { return false }

        let lowercaseTitle = title.lowercased()
        for heuristic in TaskAssistantSettings.builtInHeuristics {
            guard isHeuristicEnabled(heuristic) else { continue }
            for pattern in heuristic.patterns {
                if lowercaseTitle.contains(pattern.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    /// Add an app to the task extraction allowed list
    func allowApp(_ appName: String) {
        var apps = allowedApps
        apps.insert(appName)
        allowedApps = apps
        log("Task: Allowed app '\(appName)' for task extraction")
    }

    /// Remove an app from the task extraction allowed list
    func disallowApp(_ appName: String) {
        var apps = allowedApps
        apps.remove(appName)
        allowedApps = apps
        log("Task: Disallowed app '\(appName)' from task extraction")
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
        allowedApps = []
        disabledHeuristicIds = []
        UserDefaults.standard.removeObject(forKey: "taskEnabledBrowserHeuristics")
        resetPromptToDefault()
    }
}
