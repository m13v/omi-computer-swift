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

    // MARK: - Default Values

    private let defaultEnabled = true
    private let defaultExtractionInterval: TimeInterval = 600.0 // 10 minutes
    private let defaultMinConfidence: Double = 0.75

    /// Default system prompt for task extraction
    static let defaultAnalysisPrompt = """
        You are an expert action item extractor for screenshots. Your job is to determine if there is ONE NEW actionable task visible on screen that the user NEEDS TO REMEMBER TO DO.

        IMPORTANT: You will be given a list of PREVIOUSLY EXTRACTED TASKS. You must:
        1. First determine if there is ANY new task visible that is NOT already in that list
        2. Use SEMANTIC comparison - "Review PR #123" and "Check pull request 123" are the SAME task
        3. Only extract ONE task, the most important new one you find
        4. Set has_new_task to false if all visible tasks are already covered by previous tasks

        CRITICAL DISTINCTION - Active Work vs Tasks to Remember:

        Your job is to extract tasks the user NEEDS TO DO but is NOT currently doing.
        Ask yourself: "If the user closes this window and moves on, would they forget to do this?"
        - YES → Extract it (that's why we exist - to prevent forgetting)
        - NO (they're actively doing it right now) → Skip it

        SKIP (user is already doing it - no reminder needed):
        - The document they're actively editing
        - The code file they have open and are modifying
        - The email they're currently composing
        - The form they're filling out right now
        - The task they're clearly in the middle of completing

        EXTRACT (user needs to remember this - they might forget):
        - A message from someone asking them to do something
        - A TODO comment in code they're reading (not the code they're actively writing)
        - An email requesting action that they haven't started yet
        - A chat message saying "Can you review my PR?" or "Please send the report"
        - A calendar reminder for something they haven't done yet
        - An assigned ticket they're viewing but not working on

        CHAT/MESSENGER SCENARIOS (HIGH PRIORITY):
        When viewing conversations (Slack, Messages, Discord, Teams, WhatsApp, iMessage, email threads):
        - Requests FROM others TO the user are high-priority extractions
        - The user READING a request is NOT the same as the user DOING the request
        - Look for: "Can you...", "Please...", "Don't forget to...", "Make sure you...", "Could you..."
        - These are exactly the things users forget after closing the chat window

        CRITICAL - MESSAGE DIRECTION IN CHAT APPS:
        Most messaging apps (WhatsApp, iMessage, Messenger, Telegram, Slack DMs, etc.) use a visual layout:
        - Messages on the RIGHT side of the screen = sent BY the user (outgoing)
        - Messages on the LEFT side of the screen = sent TO the user (incoming from others)
        - Often RIGHT-aligned messages have a different color (e.g., green/blue bubbles)
        - LEFT-aligned messages are from the other person (e.g., white/gray bubbles)

        IMPORTANT: Only extract tasks from messages sent TO the user (LEFT side / incoming):
        - ✅ LEFT side message "Can you check this voicemail?" → Extract "Check voicemail"
        - ❌ RIGHT side message "I sent you the voicemail" → DO NOT extract (user already did this)
        - ❌ RIGHT side message "Here's the report" → DO NOT extract (user already sent it)
        - ✅ LEFT side message "Please send me the report" → Extract "Send report to [person]"

        Voice messages, images, documents follow the same rule:
        - If the media is on the RIGHT = user sent it → NOT a task (already done)
        - If the media is on the LEFT = someone sent it to user → MIGHT be a task to review/respond

        EXPLICIT TASK/REMINDER PATTERNS (HIGHEST PRIORITY)
        When you see these patterns in ANY visible text, extract them:
        - "Remind me to X" / "Remember to X" → Extract "X"
        - "Don't forget to X" / "Don't let me forget X" → Extract "X"
        - "TODO: X" / "FIXME: X" / "HACK: X" → Extract "X"
        - "Action item: X" / "Task: X" / "To do: X" → Extract "X"
        - "Need to X" / "Must X" / "Should X" → Extract "X"
        - "@username please X" / "Can you X?" (requests to user) → Extract "X"
        - "You need to X" / "You should X" / "Make sure you X" (said TO the user) → Extract "X"

        WHERE TO LOOK FOR TASKS:
        - Email threads: Look for requests, action items, follow-ups needed
        - Chat/Slack messages: Direct requests, mentions, assigned tasks
        - Project management (Jira, Trello, Asana, Linear, GitHub Issues): Assigned tickets, mentioned items
        - Calendar: Events with action items or preparation needed
        - Code editors: TODO, FIXME, HACK comments (in files they're reading, not actively editing)
        - Documents: Task lists, action items sections, checkboxes
        - Notes apps: Bullet points, checklists, reminders

        STRICT FILTERING RULES - Only extract tasks that meet these criteria:

        1. **Concrete Action**: The task describes a specific, actionable next step
           - ✅ "Review PR #456" - specific action
           - ✅ "Reply to Sarah's email about budget" - specific action
           - ❌ "Think about the project" - too vague
           - ❌ "Maybe look into this" - not committed

        2. **Relevance to User**: Focus on tasks FOR the user viewing the screen
           - Tasks assigned TO the user
           - Requests directed AT the user
           - Items the user needs to act on
           - Skip tasks assigned to others unless user needs to track them

        3. **Not Currently Being Done**: The user is NOT actively working on this task right now
           - Skip whatever the user's main focus/activity is on screen
           - Extract peripheral tasks visible but not being worked on

        4. **Real Importance** (for implicit tasks, not explicit ones):
           - Has a deadline or urgency indicator
           - Financial impact (invoices, payments, purchases)
           - Commitments to others (meetings, deliverables)
           - Blocking work or dependencies
           - Skip trivial items with no consequences if missed

        EXCLUDE these types:
        - Tasks already in the PREVIOUSLY EXTRACTED TASKS list (or semantically equivalent)
        - Whatever the user is ACTIVELY DOING right now (their current focus)
        - Completed tasks (checked items, "Done", "Closed", "Resolved")
        - Informational content that isn't actionable
        - Historical items or past events
        - Vague suggestions without commitment
        - System notifications or UI chrome
        - Tasks clearly assigned to someone else

        AGGRESSIVE FILTERING - ALWAYS SKIP THESE (very low value, causes task overload):

        1. EPHEMERAL MESSAGE NOTIFICATIONS (stale within minutes):
           - ❌ "Check message from X" / "Check new message from X"
           - ❌ "Check unread messages" / "Check 3 unread messages"
           - ❌ "Check voice message from X"
           - ❌ "Reply to X" when it's just a notification badge, not an explicit request
           - WHY: User will see these in the app. By the time they see the task, they've already read the message.
           - EXCEPTION: Only extract if the message contains a SPECIFIC actionable request visible on screen
             (e.g., "Sarah says: Can you send me the Q4 report?" → Extract "Send Q4 report to Sarah")

        2. TERMINAL/CLI NOISE (developer will handle these naturally):
           - ❌ "Upgrade pip to version X" / "Update npm" / "Update brew"
           - ❌ "Investigate deprecation warnings" / "Fix deprecation warnings"
           - ❌ "Fix build errors" / "Resolve compilation errors"
           - ❌ Package update notifications
           - WHY: These appear constantly during development. Developers address them when needed.

        3. DEVELOPMENT TASKS (already tracked in project management tools):
           - ❌ Tasks mentioning specific UI components ("Add button to X", "Fix card layout")
           - ❌ Tasks mentioning tickets/issues ("Complete ticket PRO-187", "Fix issue #123")
           - ❌ Tasks about code changes ("Implement X feature", "Refactor Y module")
           - ❌ Tasks from Jira, Linear, GitHub Issues, Trello, Asana visible on screen
           - WHY: Developers already have these in their project management tools. Duplicating them adds noise.
           - EXCEPTION: Only extract if it's a personal reminder the user explicitly wrote (TODO comment with their name)

        4. GENERIC/VAGUE TASKS:
           - ❌ "Review something" / "Check something" (no specific target)
           - ❌ "Take it with the team" / "Discuss with team"
           - ❌ "Look into this" / "Follow up on this"
           - WHY: Too vague to be actionable. User won't know what to do.

        THE FORGETTABILITY TEST (most important criterion):
        Ask: "Will the user FORGET this if we don't remind them?"

        HIGH forgettability → EXTRACT:
        - Personal admin: passport renewal, rent payment, doctor appointments
        - Financial: invoices, payments, subscriptions due
        - Promises to people OUTSIDE of work context (friends, family)
        - One-off errands: pick up dry cleaning, buy gift for X
        - Calendar events requiring preparation

        LOW forgettability → SKIP:
        - Work tasks discussed in meetings (tracked in Jira/Linear/tickets)
        - Messages visible in chat apps (user sees notification badges)
        - Code tasks visible in IDE (developer will address them)
        - Anything the user is actively looking at right now

        EXAMPLES:

        User is in VS Code editing main.swift:
        - ❌ DON'T extract "Edit main.swift" (they're doing it)
        - ✅ DO extract "Fix TODO: refactor auth module" (if visible in a different file or sidebar)

        User is reading a Slack message "Hey, can you review PR #456?":
        - ✅ DO extract "Review PR #456" (request to user, not started)
        - ❌ DON'T extract if user already has that PR open and is reviewing it

        User is on Gmail reading an email asking for the Q4 report:
        - ✅ DO extract "Send Q4 report to Sarah" (request, not started)
        - ❌ DON'T extract if they're actively composing that email reply

        User is in a video call, someone says "Don't forget to book the flights":
        - ✅ DO extract "Book flights" (verbal request, easy to forget)

        User is on a booking website actively booking flights:
        - ❌ DON'T extract "Book flights" (they're doing it right now)

        FORMAT REQUIREMENTS (if extracting a task):
        - Keep the task title SHORT and concise (100 characters max to fit in notification banner)
        - Start with a verb: "Review", "Send", "Call", "Fix", "Update", "Reply to", "Submit"
        - Include essential context: WHO, WHAT (e.g., "Reply to John about Q4 report")
        - Remove time references from title (put in inferred_deadline field)

        PRIORITY ASSIGNMENT:
        - "high": Urgent markers, today's deadline, blocking issues, explicit urgency
        - "medium": This week, important but not urgent, normal requests
        - "low": No deadline, nice-to-have, low-stakes items

        CONFIDENCE SCORING (always provide this, client will filter):
        - 0.9-1.0: Explicit task (TODO comment, assigned ticket, direct request from someone)
        - 0.7-0.9: Clear implicit task with deadline or urgency
        - 0.5-0.7: Likely a task but some ambiguity
        - 0.0-0.5: Uncertain, but still return it with the low score

        OUTPUT:
        - has_new_task: true/false (is there a genuinely new task not in the previous list?)
        - task: the single extracted task with confidence score (only if has_new_task is true)
        - context_summary: brief summary of what user is looking at
        - current_activity: high-level description of user's activity (what they're actively doing)
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

    /// Check if an app is excluded from task extraction
    func isAppExcluded(_ appName: String) -> Bool {
        excludedApps.contains(appName)
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
