import Foundation

/// Task extraction assistant that identifies tasks and action items from screen content
/// Uses single-stage Gemini tool calling with vector + FTS5 search for deduplication
actor TaskAssistant: ProactiveAssistant {
    // MARK: - ProactiveAssistant Protocol

    nonisolated let identifier = "task-extraction"
    nonisolated let displayName = "Task Extractor"

    var isEnabled: Bool {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.isEnabled
            }
        }
    }

    // MARK: - Properties

    private let geminiClient: GeminiClient
    private var isRunning = false
    private var previousTasks: [ExtractedTask] = [] // Last 10 extracted tasks for context
    private let maxPreviousTasks = 10
    private var currentApp: String?
    private var processingTask: Task<Void, Never>?

    // MARK: - Event-Driven Trigger System
    private enum TriggerEvent {
        case contextSwitch(CapturedFrame)  // departing frame from context being left
        case timerFallback(CapturedFrame)  // latest frame after extraction interval
    }

    private let triggerStream: AsyncStream<TriggerEvent>
    private let triggerContinuation: AsyncStream<TriggerEvent>.Continuation

    /// Always holds the most recent frame for fallback timer use
    private var latestFrame: CapturedFrame?
    /// Fallback timer that fires after extractionInterval if no context switch occurs
    private var fallbackTimerTask: Task<Void, Never>?

    // Cached goals (refreshed every 5 minutes)
    private var cachedGoals: [Goal] = []
    private var lastGoalsRefresh: Date = .distantPast
    private let goalsRefreshInterval: TimeInterval = 300

    // MARK: - Due Date Helpers

    /// Parse an inferred deadline string into a Date, or default to end of today.
    /// Tries ISO8601, then common natural language patterns.
    private func parseDueDate(from inferredDeadline: String?) -> Date {
        if let deadline = inferredDeadline, !deadline.isEmpty {
            // Try ISO8601 first (e.g. "2025-10-04T14:00:00Z")
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: deadline) {
                return date
            }
            // Try common date formats
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd",
                "MM/dd/yyyy",
                "MMMM d, yyyy"
            ]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: deadline) {
                    return date
                }
            }
            log("Task: Could not parse inferred_deadline '\(deadline)', defaulting to end of today")
        }
        // Default: end of today (11:59 PM local time)
        return Self.endOfToday()
    }

    /// Returns 11:59 PM today in the user's local timezone
    private static func endOfToday() -> Date {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: 23, minute: 59, second: 0, of: startOfDay) ?? startOfDay
    }

    /// Get the current system prompt from settings (accessed on MainActor for thread safety)
    private var systemPrompt: String {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.analysisPrompt
            }
        }
    }

    /// Get the extraction interval from settings
    private var extractionInterval: TimeInterval {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.extractionInterval
            }
        }
    }

    /// Get the minimum confidence threshold from settings
    private var minConfidence: Double {
        get async {
            await MainActor.run {
                TaskAssistantSettings.shared.minConfidence
            }
        }
    }

    // MARK: - Initialization

    init(apiKey: String? = nil) throws {
        // Use Gemini 3 Pro for better task extraction quality
        self.geminiClient = try GeminiClient(apiKey: apiKey, model: "gemini-3-pro-preview")

        let (stream, continuation) = AsyncStream.makeStream(of: TriggerEvent.self, bufferingPolicy: .bufferingNewest(1))
        self.triggerStream = stream
        self.triggerContinuation = continuation

        // Start processing loop + embedding index
        Task {
            await self.startProcessing()
            await self.initializeEmbeddings()
        }
    }

    // MARK: - Embedding Lifecycle

    /// Load embedding index and kick off backfill
    private func initializeEmbeddings() async {
        await EmbeddingService.shared.loadIndex()
        // Backfill in background
        Task {
            await EmbeddingService.shared.backfillIfNeeded()
        }
    }

    // MARK: - Processing

    private func startProcessing() {
        isRunning = true
        processingTask = Task {
            await processLoop()
        }
    }

    private func processLoop() async {
        log("Task assistant started (event-driven)")

        for await trigger in triggerStream {
            guard isRunning else { break }

            let (frame, triggerType): (CapturedFrame, String) = {
                switch trigger {
                case .contextSwitch(let f): return (f, "context_switch")
                case .timerFallback(let f): return (f, "timer_fallback")
                }
            }()

            log("Task: Processing \(triggerType) trigger from \(frame.appName) (window: \(frame.windowTitle ?? "nil"))")

            // Cancel fallback timer before processing
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil

            await processFrame(frame)

            // Start a new fallback timer after processing
            startFallbackTimer()
        }

        log("Task assistant stopped")
    }

    /// Start (or restart) the fallback timer that fires after extractionInterval
    private func startFallbackTimer() {
        fallbackTimerTask?.cancel()
        fallbackTimerTask = Task {
            let interval = await self.extractionInterval
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let frame = self.latestFrame else { return }
            log("Task: Fallback timer fired after \(Int(interval))s")
            self.triggerContinuation.yield(.timerFallback(frame))
        }
    }

    // MARK: - Test Analysis (for test runner)

    /// Run the extraction pipeline on arbitrary JPEG data without side effects (no saving, no events).
    /// Used by the test runner to replay past screenshots.
    /// Returns (result, searchCount) where searchCount is the number of search tool calls made.
    func testAnalyze(jpegData: Data, appName: String) async throws -> (TaskExtractionResult?, Int) {
        return try await extractTaskSingleStage(from: jpegData, appName: appName)
    }

    // MARK: - ProactiveAssistant Protocol Methods

    func shouldAnalyze(frameNumber: Int, timeSinceLastAnalysis: TimeInterval) -> Bool {
        return true
    }

    func analyze(frame: CapturedFrame) async -> AssistantResult? {
        // Only analyze apps on the whitelist
        let allowed = await MainActor.run { TaskAssistantSettings.shared.isAppAllowed(frame.appName) }
        if !allowed {
            return nil
        }

        // For browser apps, also check window title against enabled heuristics
        let windowAllowed = await MainActor.run {
            TaskAssistantSettings.shared.isWindowAllowed(appName: frame.appName, windowTitle: frame.windowTitle)
        }
        if !windowAllowed {
            return nil
        }

        // Store as latest frame (used by fallback timer and context switch)
        latestFrame = frame

        // Start fallback timer if not already running
        if fallbackTimerTask == nil {
            startFallbackTimer()
        }

        return nil
    }

    func handleResult(_ result: AssistantResult, sendEvent: @escaping (String, [String: Any]) -> Void) async {
        guard let taskResult = result as? TaskExtractionResult else { return }
        await handleResultWithScreenshot(taskResult, screenshotId: nil, appName: "Unknown", sendEvent: sendEvent)
    }

    /// Handle result with screenshot ID for SQLite storage
    private func handleResultWithScreenshot(
        _ taskResult: TaskExtractionResult,
        screenshotId: Int64?,
        appName: String,
        windowTitle: String? = nil,
        sendEvent: @escaping (String, [String: Any]) -> Void
    ) async {
        // Save observation for every result (fire-and-forget)
        let observationApp = taskResult.task?.sourceApp ?? appName
        let observation = ObservationRecord(
            screenshotId: screenshotId,
            appName: observationApp,
            contextSummary: taskResult.contextSummary,
            currentActivity: taskResult.currentActivity,
            hasTask: taskResult.hasNewTask,
            taskTitle: taskResult.task?.title,
            sourceCategory: taskResult.task?.sourceCategory,
            sourceSubcategory: taskResult.task?.sourceSubcategory,
            createdAt: Date()
        )
        Task {
            do {
                try await ActionItemStorage.shared.insertObservation(observation)
            } catch {
                logError("Task: Failed to insert observation", error: error)
            }
        }

        guard taskResult.hasNewTask, let task = taskResult.task else {
            return
        }

        let threshold = await minConfidence
        let confidencePercent = Int(task.confidence * 100)

        guard task.confidence >= threshold else {
            log("Task: [\(confidencePercent)% < \(Int(threshold * 100))%] Filtered: \"\(task.title)\"")
            return
        }

        log("Task: [\(confidencePercent)% conf.] \"\(task.title)\"")

        previousTasks.insert(task, at: 0)
        if previousTasks.count > maxPreviousTasks {
            previousTasks.removeLast()
        }

        // Save to SQLite + generate embedding
        let extractionRecord = await saveTaskToSQLite(
            task: task,
            screenshotId: screenshotId,
            contextSummary: taskResult.contextSummary,
            windowTitle: windowTitle
        )

        // Generate embedding for new task in background
        if let recordId = extractionRecord?.id {
            Task {
                await self.generateEmbeddingForTask(id: recordId, text: task.title)
            }
        }

        // Sync to backend
        if let backendId = await syncTaskToBackend(task: task, taskResult: taskResult, windowTitle: windowTitle) {
            if let recordId = extractionRecord?.id {
                do {
                    try await ActionItemStorage.shared.markSynced(id: recordId, backendId: backendId)
                } catch {
                    logError("Task: Failed to update sync status", error: error)
                }
            }
        }

        await MainActor.run {
            AnalyticsManager.shared.taskExtracted(taskCount: 1)
        }

        await sendTaskNotification(task: task)

        sendEvent("taskExtracted", [
            "assistant": identifier,
            "task": task.toDictionary(),
            "contextSummary": taskResult.contextSummary
        ])
    }

    /// Generate embedding for a newly saved task and store it
    private func generateEmbeddingForTask(id: Int64, text: String) async {
        do {
            let embedding = try await EmbeddingService.shared.embed(text: text)
            let data = await EmbeddingService.shared.floatsToData(embedding)
            try await ActionItemStorage.shared.updateEmbedding(id: id, embedding: data)
            await EmbeddingService.shared.addToIndex(id: id, embedding: embedding)
            log("Task: Generated embedding for task \(id)")
        } catch {
            logError("Task: Failed to generate embedding for task \(id)", error: error)
        }
    }

    /// Save extracted task to SQLite using ActionItemStorage
    private func saveTaskToSQLite(
        task: ExtractedTask,
        screenshotId: Int64?,
        contextSummary: String,
        windowTitle: String? = nil
    ) async -> ActionItemRecord? {
        var metadata: [String: Any] = [
            "tags": task.tags,
            "context_summary": contextSummary,
            "source_category": task.sourceCategory,
            "source_subcategory": task.sourceSubcategory
        ]
        if let primaryTag = task.primaryTag {
            metadata["category"] = primaryTag
        }
        if let deadline = task.inferredDeadline {
            metadata["inferred_deadline"] = deadline
        }
        if let windowTitle = windowTitle {
            metadata["window_title"] = windowTitle
        }

        let metadataJson: String?
        if let data = try? JSONSerialization.data(withJSONObject: metadata),
           let json = String(data: data, encoding: .utf8) {
            metadataJson = json
        } else {
            metadataJson = nil
        }

        let tagsJson: String?
        if let data = try? JSONEncoder().encode(task.tags),
           let json = String(data: data, encoding: .utf8) {
            tagsJson = json
        } else {
            tagsJson = nil
        }

        let dueAt = parseDueDate(from: task.inferredDeadline)

        let record = ActionItemRecord(
            backendSynced: false,
            description: task.title,
            source: "screenshot",
            priority: task.priority.rawValue,
            category: task.primaryTag,
            tagsJson: tagsJson,
            dueAt: dueAt,
            screenshotId: screenshotId,
            confidence: task.confidence,
            sourceApp: task.sourceApp,
            windowTitle: windowTitle,
            contextSummary: contextSummary,
            metadataJson: metadataJson
        )

        do {
            let inserted = try await ActionItemStorage.shared.insertLocalActionItem(record)
            log("Task: Saved to SQLite (id: \(inserted.id ?? -1))")
            return inserted
        } catch {
            logError("Task: Failed to save to SQLite", error: error)
            return nil
        }
    }

    /// Sync task to backend API, returns backend ID if successful
    private func syncTaskToBackend(task: ExtractedTask, taskResult: TaskExtractionResult, windowTitle: String? = nil) async -> String? {
        do {
            var metadata: [String: Any] = [
                "source_app": task.sourceApp,
                "confidence": task.confidence,
                "context_summary": taskResult.contextSummary,
                "current_activity": taskResult.currentActivity,
                "tags": task.tags,
                "source_category": task.sourceCategory,
                "source_subcategory": task.sourceSubcategory
            ]
            if let primaryTag = task.primaryTag {
                metadata["category"] = primaryTag
            }
            if let reasoning = task.description {
                metadata["reasoning"] = reasoning
            }
            if let deadline = task.inferredDeadline {
                metadata["inferred_deadline"] = deadline
            }
            if let windowTitle = windowTitle {
                metadata["window_title"] = windowTitle
            }

            let dueAt = parseDueDate(from: task.inferredDeadline)

            let response = try await APIClient.shared.createActionItem(
                description: task.title,
                dueAt: dueAt,
                source: "screenshot",
                priority: task.priority.rawValue,
                category: task.primaryTag,
                metadata: metadata
            )

            log("Task: Synced to backend (id: \(response.id))")
            return response.id
        } catch {
            logError("Task: Failed to sync to backend", error: error)
            return nil
        }
    }

    /// Send a notification for the extracted task
    private func sendTaskNotification(task: ExtractedTask) async {
        let message = task.title
        await MainActor.run {
            NotificationService.shared.sendNotification(
                title: "Task",
                message: message,
                assistantId: identifier
            )
        }
    }

    func onAppSwitch(newApp: String) async {
        if newApp != currentApp {
            if let currentApp = currentApp {
                log("Task: APP SWITCH: \(currentApp) -> \(newApp)")
            } else {
                log("Task: Active app: \(newApp)")
            }
            currentApp = newApp
        }
    }

    func onContextSwitch(departingFrame: CapturedFrame?, newApp: String, newWindowTitle: String?) async {
        // Use latestFrame if departing frame is unavailable or stale (from a different app due to delay periods)
        let frame: CapturedFrame? = {
            if let departing = departingFrame {
                return departing
            }
            return latestFrame
        }()

        guard let frame = frame else {
            log("Task: Context switch but no frame available")
            return
        }

        // Check frame's app is on the whitelist
        let allowed = await MainActor.run { TaskAssistantSettings.shared.isAppAllowed(frame.appName) }
        if !allowed {
            log("Task: Context switch from non-whitelisted app '\(frame.appName)', skipping")
            // Still cancel fallback timer on any context switch
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil
            return
        }

        // Check window is allowed for browser apps
        let windowAllowed = await MainActor.run {
            TaskAssistantSettings.shared.isWindowAllowed(appName: frame.appName, windowTitle: frame.windowTitle)
        }
        if !windowAllowed {
            log("Task: Context switch from filtered browser window, skipping")
            fallbackTimerTask?.cancel()
            fallbackTimerTask = nil
            return
        }

        log("Task: Context switch from \(frame.appName) (window: \(frame.windowTitle ?? "nil")) -> \(newApp)")

        // Cancel fallback timer — context switch replaces it
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil

        // Yield context switch trigger with the frame
        triggerContinuation.yield(.contextSwitch(frame))
    }

    func clearPendingWork() async {
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil
        log("Task: Cleared fallback timer")
    }

    func stop() async {
        isRunning = false
        fallbackTimerTask?.cancel()
        fallbackTimerTask = nil
        triggerContinuation.finish()
        processingTask?.cancel()
        latestFrame = nil
    }

    // MARK: - Single-Stage Analysis with Tool Calling

    private func processFrame(_ frame: CapturedFrame) async {
        let enabled = await isEnabled
        guard enabled else {
            log("Task: Skipping analysis (disabled)")
            return
        }

        log("Task: Analyzing frame from \(frame.appName)...")
        do {
            let (result, searchCount) = try await extractTaskSingleStage(from: frame.jpegData, appName: frame.appName)
            guard let result = result else {
                log("Task: Analysis returned no result")
                return
            }

            log("Task: Analysis complete - hasNewTask: \(result.hasNewTask), context: \(result.contextSummary), searches: \(searchCount)")

            await handleResultWithScreenshot(result, screenshotId: frame.screenshotId, appName: frame.appName, windowTitle: frame.windowTitle) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("Task extraction error", error: error)
        }
    }

    /// Loop-based extraction: image analysis + iterative tool calling for search + terminal tool for decision
    /// Returns (result, searchCount) where searchCount is the number of search tool calls made.
    private func extractTaskSingleStage(from jpegData: Data, appName: String) async throws -> (TaskExtractionResult?, Int) {
        // 1. Gather context
        let context = await refreshContext()

        // 2. Build prompt with injected context
        var prompt = "Screenshot from \(appName). Analyze this screenshot for any unaddressed request directed at the user.\n\n"

        // Inject AI user profile for context
        if let profile = await AIUserProfileService.shared.getLatestProfile() {
            prompt += "USER PROFILE (who this user is — use for context, not as a task source):\n"
            prompt += profile.profileText + "\n\n"
        }

        if !context.activeTasks.isEmpty {
            prompt += "ACTIVE TASKS (user is already tracking these):\n"
            for (i, task) in context.activeTasks.enumerated() {
                let pri = task.priority.map { " [\($0)]" } ?? ""
                prompt += "\(i + 1). \(task.description)\(pri)\n"
            }
            prompt += "\n"
        }

        if !context.completedTasks.isEmpty {
            prompt += "RECENTLY COMPLETED TASKS (user already handled these — they attracted user attention and seemed relevant enough to complete. Do not re-extract these or very similar tasks, but related follow-ups are okay):\n"
            for (i, task) in context.completedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        if !context.deletedTasks.isEmpty {
            prompt += "USER-DELETED TASKS (user explicitly rejected these — do not re-extract similar):\n"
            for (i, task) in context.deletedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        if !context.goals.isEmpty {
            prompt += "ACTIVE GOALS:\n"
            for (i, goal) in context.goals.enumerated() {
                prompt += "\(i + 1). \(goal.title)"
                if let desc = goal.description {
                    prompt += " — \(desc)"
                }
                prompt += "\n"
            }
            prompt += "\n"
        }

        prompt += """
        Analyze this screenshot. If you see a potential request, search for duplicates first.
        If there is clearly no request on screen (~90% of screenshots), call no_task_found immediately.
        """

        // 3. Define 5 tools
        let tools = GeminiTool(functionDeclarations: [
            GeminiTool.FunctionDeclaration(
                name: "search_similar",
                description: "Search for semantically similar existing tasks using vector similarity. Call this when you see a potential request and want to check for duplicates.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "A concise description of the potential task to search for")
                    ],
                    required: ["query"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "search_keywords",
                description: "Search for existing tasks matching specific keywords. Use this for precise keyword-based matching complementing vector search.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "Keywords to search for in existing tasks")
                    ],
                    required: ["query"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "no_task_found",
                description: "Call this when there is no actionable request on screen. This is the most common outcome (~90% of screenshots). Use for: code editors, terminals, settings, media players, dashboards, or any screen without a direct request from another person or AI.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "context_summary": .init(type: "string", description: "Brief summary of what the user is looking at"),
                        "current_activity": .init(type: "string", description: "What the user is actively doing")
                    ],
                    required: ["context_summary", "current_activity"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "extract_task",
                description: "Extract a new task that is not already tracked. Call ONLY after searching for duplicates. All fields are required.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "title": .init(type: "string", description: "Verb-first task title, 6–15 words. MUST name a specific person/project/artifact and a concrete action. If you can't write 6+ specific words, call no_task_found instead."),
                        "description": .init(type: "string", description: "Additional context about the task. Empty string if none."),
                        "priority": .init(type: "string", description: "Task priority", enumValues: ["high", "medium", "low"]),
                        "tags": .init(type: "array", description: "1-3 relevant tags", items: .init(type: "string")),
                        "source_app": .init(type: "string", description: "App where the task was found"),
                        "inferred_deadline": .init(type: "string", description: "Deadline if visible or implied. Empty string if none."),
                        "confidence": .init(type: "number", description: "Confidence score 0.0-1.0"),
                        "context_summary": .init(type: "string", description: "Brief summary of what user is looking at"),
                        "current_activity": .init(type: "string", description: "What the user is actively doing"),
                        "source_category": .init(type: "string", description: "Where the task originated", enumValues: ["direct_request", "self_generated", "calendar_driven", "reactive", "external_system", "other"]),
                        "source_subcategory": .init(type: "string", description: "Specific origin within category", enumValues: ["message", "meeting", "mention", "idea", "reminder", "goal_subtask", "event_prep", "recurring", "deadline", "error", "notification", "observation", "project_tool", "alert", "documentation", "other"])
                    ],
                    required: ["title", "description", "priority", "tags", "source_app", "inferred_deadline", "confidence", "context_summary", "current_activity", "source_category", "source_subcategory"]
                )
            ),
            GeminiTool.FunctionDeclaration(
                name: "reject_task",
                description: "Reject task extraction — the potential task is a duplicate, already completed, or was previously rejected by the user. Call after searching confirms this.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "reason": .init(type: "string", description: "Why this task was rejected (e.g. 'duplicate of existing active task', 'already completed')"),
                        "context_summary": .init(type: "string", description: "Brief summary of what user is looking at"),
                        "current_activity": .init(type: "string", description: "What the user is actively doing")
                    ],
                    required: ["reason", "context_summary", "current_activity"]
                )
            )
        ])

        // 4. Get system prompt
        let currentSystemPrompt = await systemPrompt

        // 5. Build initial contents
        let base64Data = jpegData.base64EncodedString()
        var contents: [GeminiImageToolRequest.Content] = [
            GeminiImageToolRequest.Content(
                role: "user",
                parts: [
                    GeminiImageToolRequest.Part(text: prompt),
                    GeminiImageToolRequest.Part(mimeType: "image/jpeg", data: base64Data)
                ]
            )
        ]

        // 6. Tool-calling loop (max 5 iterations)
        var searchCount = 0

        for iteration in 0..<5 {
            let result = try await geminiClient.sendImageToolLoop(
                contents: contents,
                systemPrompt: currentSystemPrompt,
                tools: [tools],
                forceToolCall: iteration == 0
            )

            guard let toolCall = result.toolCalls.first else {
                log("Task: No tool call received on iteration \(iteration), breaking")
                break
            }

            switch toolCall.name {
            case "no_task_found":
                let contextSummary = toolCall.arguments["context_summary"] as? String ?? "No task on screen"
                let currentActivity = toolCall.arguments["current_activity"] as? String ?? "Unknown"
                log("Task: no_task_found — \(contextSummary)")
                return (TaskExtractionResult(
                    hasNewTask: false,
                    task: nil,
                    contextSummary: contextSummary,
                    currentActivity: currentActivity
                ), searchCount)

            case "extract_task":
                let title = toolCall.arguments["title"] as? String ?? ""
                let contextSummary = toolCall.arguments["context_summary"] as? String ?? ""
                let currentActivity = toolCall.arguments["current_activity"] as? String ?? ""

                // --- Hard validation: reject vague titles and ask the model to retry ---
                let titleWords = title.split(separator: " ").count
                let validationError = Self.validateTaskTitle(title, wordCount: titleWords)
                if let error = validationError {
                    log("Task: Title rejected (\(error)): \"\(title)\"")

                    // Feed rejection back into the loop so the model can retry with more specifics
                    contents.append(GeminiImageToolRequest.Content(
                        role: "model",
                        parts: [GeminiImageToolRequest.Part(
                            functionCall: .init(name: toolCall.name, args: toolCall.arguments as? [String: String] ?? ["title": title]),
                            thoughtSignature: toolCall.thoughtSignature
                        )]
                    ))
                    contents.append(GeminiImageToolRequest.Content(
                        role: "user",
                        parts: [GeminiImageToolRequest.Part(functionResponse: .init(
                            name: toolCall.name,
                            response: .init(result: """
                                REJECTED: \(error). \
                                Your title was: "\(title)" (\(titleWords) words). \
                                Either rewrite with 6+ words including a specific person/project name and concrete action, \
                                or call no_task_found if you cannot be more specific.
                                """)
                        ))]
                    ))
                    continue
                }

                let description = toolCall.arguments["description"] as? String
                let priorityStr = toolCall.arguments["priority"] as? String ?? "medium"
                let priority = TaskPriority(rawValue: priorityStr) ?? .medium
                let tags: [String]
                if let tagArray = toolCall.arguments["tags"] as? [Any] {
                    tags = tagArray.compactMap { $0 as? String }
                } else {
                    tags = []
                }
                let sourceApp = toolCall.arguments["source_app"] as? String ?? appName
                let inferredDeadline = toolCall.arguments["inferred_deadline"] as? String
                let confidence: Double
                if let confValue = toolCall.arguments["confidence"] as? Double {
                    confidence = confValue
                } else if let confInt = toolCall.arguments["confidence"] as? Int {
                    confidence = Double(confInt)
                } else {
                    confidence = 0.5
                }
                let sourceCategory = toolCall.arguments["source_category"] as? String ?? "other"
                let sourceSubcategory = toolCall.arguments["source_subcategory"] as? String ?? "other"

                let task = ExtractedTask(
                    title: title,
                    description: description?.isEmpty == true ? nil : description,
                    priority: priority,
                    sourceApp: sourceApp,
                    inferredDeadline: inferredDeadline?.isEmpty == true ? nil : inferredDeadline,
                    confidence: confidence,
                    tags: tags,
                    sourceCategory: sourceCategory,
                    sourceSubcategory: sourceSubcategory
                )

                log("Task: extract_task — \"\(title)\" (confidence: \(confidence), priority: \(priorityStr))")
                return (TaskExtractionResult(
                    hasNewTask: true,
                    task: task,
                    contextSummary: contextSummary,
                    currentActivity: currentActivity
                ), searchCount)

            case "reject_task":
                let reason = toolCall.arguments["reason"] as? String ?? "Unknown reason"
                let contextSummary = toolCall.arguments["context_summary"] as? String ?? ""
                let currentActivity = toolCall.arguments["current_activity"] as? String ?? ""
                log("Task: reject_task — \(reason)")
                return (TaskExtractionResult(
                    hasNewTask: false,
                    task: nil,
                    contextSummary: contextSummary,
                    currentActivity: currentActivity
                ), searchCount)

            case "search_similar":
                let query = toolCall.arguments["query"] as? String ?? ""
                searchCount += 1
                log("Task: search_similar query: \"\(query)\"")
                let searchResults = await executeVectorSearch(query: query)
                log("Task: Vector search returned \(searchResults.count) results")

                let searchResultsJson: String
                if let data = try? JSONEncoder().encode(searchResults),
                   let json = String(data: data, encoding: .utf8) {
                    searchResultsJson = json
                } else {
                    searchResultsJson = "[]"
                }

                // Append model's tool call + function response to contents
                contents.append(GeminiImageToolRequest.Content(
                    role: "model",
                    parts: [GeminiImageToolRequest.Part(
                        functionCall: .init(name: toolCall.name, args: ["query": query]),
                        thoughtSignature: toolCall.thoughtSignature
                    )]
                ))
                contents.append(GeminiImageToolRequest.Content(
                    role: "user",
                    parts: [GeminiImageToolRequest.Part(functionResponse: .init(
                        name: toolCall.name,
                        response: .init(result: searchResultsJson)
                    ))]
                ))
                continue

            case "search_keywords":
                let query = toolCall.arguments["query"] as? String ?? ""
                searchCount += 1
                log("Task: search_keywords query: \"\(query)\"")
                let searchResults = await executeKeywordSearch(query: query)
                log("Task: Keyword search returned \(searchResults.count) results")

                let searchResultsJson: String
                if let data = try? JSONEncoder().encode(searchResults),
                   let json = String(data: data, encoding: .utf8) {
                    searchResultsJson = json
                } else {
                    searchResultsJson = "[]"
                }

                // Append model's tool call + function response to contents
                contents.append(GeminiImageToolRequest.Content(
                    role: "model",
                    parts: [GeminiImageToolRequest.Part(
                        functionCall: .init(name: toolCall.name, args: ["query": query]),
                        thoughtSignature: toolCall.thoughtSignature
                    )]
                ))
                contents.append(GeminiImageToolRequest.Content(
                    role: "user",
                    parts: [GeminiImageToolRequest.Part(functionResponse: .init(
                        name: toolCall.name,
                        response: .init(result: searchResultsJson)
                    ))]
                ))
                continue

            default:
                log("Task: Unknown tool call: \(toolCall.name), breaking")
                break
            }
        }

        log("Task: Completed in \(searchCount) searches (loop exhausted without terminal tool)")
        return (nil, searchCount)
    }

    // MARK: - Title Validation

    /// Validates a task title for minimum specificity. Returns an error message if invalid, nil if OK.
    private static func validateTaskTitle(_ title: String, wordCount: Int) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Must not be empty
        if trimmed.isEmpty {
            return "Title is empty"
        }

        // Minimum 6 words
        if wordCount < 6 {
            return "Title too short (\(wordCount) words, minimum 6)"
        }

        // Reject titles that are purely generic verbs with no specifics
        let genericPatterns: [String] = [
            "investigate", "check logs", "clean up", "look into",
            "look through", "update to", "fix the", "review the",
            "check the", "modify the", "track the"
        ]
        let lowered = trimmed.lowercased()
        for pattern in genericPatterns {
            // If the entire title is just a generic pattern (possibly with 1-2 filler words), reject
            if lowered == pattern || (wordCount <= 4 && lowered.hasPrefix(pattern)) {
                return "Title too generic (matches vague pattern '\(pattern)')"
            }
        }

        // Must contain at least one capitalized proper noun (person, project, app name)
        // Heuristic: after the first word (verb), there should be at least one word starting with uppercase
        let words = trimmed.split(separator: " ")
        let hasProperNoun = words.dropFirst().contains { word in
            guard let first = word.first else { return false }
            return first.isUppercase
        }
        if !hasProperNoun {
            return "Title lacks a specific name (person, project, or app) — no proper nouns found after the verb"
        }

        return nil
    }

    // MARK: - Context & Search

    /// Refresh context from local SQLite + cached goals
    private func refreshContext() async -> TaskExtractionContext {
        var activeTasks: [(id: Int64, description: String, priority: String?)] = []
        var completedTasks: [(id: Int64, description: String)] = []
        var deletedTasks: [(id: Int64, description: String)] = []

        do {
            activeTasks = try await ActionItemStorage.shared.getRecentActiveTasks(limit: 30)
        } catch {
            logError("Task: Failed to load active tasks", error: error)
        }

        do {
            completedTasks = try await ActionItemStorage.shared.getRecentCompletedTasks(limit: 10)
        } catch {
            logError("Task: Failed to load completed tasks", error: error)
        }

        do {
            deletedTasks = try await ActionItemStorage.shared.getRecentDeletedTasks(limit: 10, deletedBy: "user")
        } catch {
            logError("Task: Failed to load deleted tasks", error: error)
        }

        // Refresh goals if stale
        let timeSinceGoals = Date().timeIntervalSince(lastGoalsRefresh)
        if timeSinceGoals >= goalsRefreshInterval {
            do {
                cachedGoals = try await APIClient.shared.getGoals()
                lastGoalsRefresh = Date()
                log("Task: Refreshed \(cachedGoals.count) goals")
            } catch {
                logError("Task: Failed to refresh goals", error: error)
            }
        }

        return TaskExtractionContext(
            activeTasks: activeTasks,
            completedTasks: completedTasks,
            deletedTasks: deletedTasks,
            goals: cachedGoals
        )
    }

    /// Execute vector similarity search
    private func executeVectorSearch(query: String) async -> [TaskSearchResult] {
        var results: [TaskSearchResult] = []

        do {
            let queryEmbedding = try await EmbeddingService.shared.embed(text: query)
            let vectorResults = await EmbeddingService.shared.searchSimilar(query: queryEmbedding, topK: 10)

            for result in vectorResults where result.similarity > 0.3 {
                if let record = try await ActionItemStorage.shared.getActionItem(id: result.id) {
                    let status: String
                    if record.deleted { status = "deleted" }
                    else if record.completed { status = "completed" }
                    else { status = "active" }

                    results.append(TaskSearchResult(
                        id: result.id,
                        description: record.description,
                        status: status,
                        similarity: Double(result.similarity),
                        matchType: "vector"
                    ))
                }
            }
        } catch {
            logError("Task: Vector search failed", error: error)
        }

        return results.sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
    }

    /// Execute FTS5 keyword search
    private func executeKeywordSearch(query: String) async -> [TaskSearchResult] {
        var results: [TaskSearchResult] = []

        do {
            let words = query.components(separatedBy: .whitespaces).filter { $0.count >= 3 }
            let ftsQuery = words.map { "\($0)*" }.joined(separator: " OR ")

            if !ftsQuery.isEmpty {
                let ftsResults = try await ActionItemStorage.shared.searchFTS(
                    query: ftsQuery,
                    limit: 10,
                    includeCompleted: true,
                    includeDeleted: true
                )

                for result in ftsResults {
                    let status: String
                    if result.deleted { status = "deleted" }
                    else if result.completed { status = "completed" }
                    else { status = "active" }

                    results.append(TaskSearchResult(
                        id: result.id,
                        description: result.description,
                        status: status,
                        similarity: nil,
                        matchType: "fts"
                    ))
                }
            }
        } catch {
            logError("Task: FTS search failed", error: error)
        }

        return results
    }
}
