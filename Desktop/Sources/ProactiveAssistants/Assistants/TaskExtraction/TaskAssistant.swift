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
    private var lastAnalysisTime: Date = .distantPast
    private var previousTasks: [ExtractedTask] = [] // Last 10 extracted tasks for context
    private let maxPreviousTasks = 10
    private var currentApp: String?
    private var pendingFrame: CapturedFrame?
    private var processingTask: Task<Void, Never>?
    private let frameSignal: AsyncStream<Void>
    private let frameSignalContinuation: AsyncStream<Void>.Continuation

    // Cached goals (refreshed every 5 minutes)
    private var cachedGoals: [Goal] = []
    private var lastGoalsRefresh: Date = .distantPast
    private let goalsRefreshInterval: TimeInterval = 300

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

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.frameSignal = stream
        self.frameSignalContinuation = continuation

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
        log("Task assistant started")

        for await _ in frameSignal {
            guard isRunning else { break }
            guard pendingFrame != nil else { continue }

            // Wait until the extraction interval has passed
            let interval = await extractionInterval
            let timeSinceLastAnalysis = Date().timeIntervalSince(lastAnalysisTime)
            if timeSinceLastAnalysis < interval {
                let remaining = interval - timeSinceLastAnalysis
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }

            // Grab the latest frame (may have been updated or cleared during sleep)
            guard let frame = pendingFrame else { continue }
            let waited = Date().timeIntervalSince(lastAnalysisTime)
            log("Task: Starting analysis (interval: \(Int(interval))s, waited: \(Int(waited))s)")
            pendingFrame = nil
            lastAnalysisTime = Date()
            await processFrame(frame)
        }

        log("Task assistant stopped")
    }

    // MARK: - Test Analysis (for test runner)

    /// Run the extraction pipeline on arbitrary JPEG data without side effects (no saving, no events).
    /// Used by the test runner to replay past screenshots.
    func testAnalyze(jpegData: Data, appName: String) async throws -> TaskExtractionResult? {
        return try await extractTaskSingleStage(from: jpegData, appName: appName)
    }

    // MARK: - ProactiveAssistant Protocol Methods

    func shouldAnalyze(frameNumber: Int, timeSinceLastAnalysis: TimeInterval) -> Bool {
        return true
    }

    func analyze(frame: CapturedFrame) async -> AssistantResult? {
        // Skip apps excluded from task extraction
        let excluded = await MainActor.run { TaskAssistantSettings.shared.isAppExcluded(frame.appName) }
        if excluded {
            log("Task: Skipping excluded app '\(frame.appName)'")
            return nil
        }

        let hadPending = pendingFrame != nil
        pendingFrame = frame
        if !hadPending {
            log("Task: Received frame from \(frame.appName), queued for analysis")
        }
        frameSignalContinuation.yield()
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
            contextSummary: taskResult.contextSummary
        )

        // Generate embedding for new task in background
        if let recordId = extractionRecord?.id {
            Task {
                await self.generateEmbeddingForTask(id: recordId, text: task.title)
            }
        }

        // Sync to backend
        if let backendId = await syncTaskToBackend(task: task, taskResult: taskResult) {
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
        contextSummary: String
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

        let record = ActionItemRecord(
            backendSynced: false,
            description: task.title,
            source: "screenshot",
            priority: task.priority.rawValue,
            category: task.primaryTag,
            tagsJson: tagsJson,
            screenshotId: screenshotId,
            confidence: task.confidence,
            sourceApp: task.sourceApp,
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
    private func syncTaskToBackend(task: ExtractedTask, taskResult: TaskExtractionResult) async -> String? {
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

            let response = try await APIClient.shared.createActionItem(
                description: task.title,
                dueAt: nil,
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

    func clearPendingWork() async {
        pendingFrame = nil
        log("Task: Cleared pending frame")
    }

    func stop() async {
        isRunning = false
        frameSignalContinuation.finish()
        processingTask?.cancel()
        pendingFrame = nil
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
            guard let result = try await extractTaskSingleStage(from: frame.jpegData, appName: frame.appName) else {
                log("Task: Analysis returned no result")
                return
            }

            log("Task: Analysis complete - hasNewTask: \(result.hasNewTask), context: \(result.contextSummary)")

            await handleResultWithScreenshot(result, screenshotId: frame.screenshotId, appName: frame.appName) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("Task extraction error", error: error)
        }
    }

    /// Single-stage extraction: image analysis + tool call for search + structured decision
    private func extractTaskSingleStage(from jpegData: Data, appName: String) async throws -> TaskExtractionResult? {
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
            prompt += "RECENTLY COMPLETED (user already did these):\n"
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
        If you see a potential request from someone, call search_similar_tasks to check for duplicates.
        If there is clearly no request on screen (code editor, terminal, settings, media, etc.), call no_task_found immediately.
        ~90% of screenshots have NO task — only extract when there is a clear, specific request from a person or AI.
        """

        // 3. Define tools: search (when potential task) + early exit (when no task)
        let tools = GeminiTool(functionDeclarations: [
            GeminiTool.FunctionDeclaration(
                name: "search_similar_tasks",
                description: "Search for existing tasks similar to a potential new task. Call this ONLY when you see a specific request from a person or AI directed at the user.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "A concise description of the potential task to search for")
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
            )
        ])

        // 4. Get system prompt
        let currentSystemPrompt = await systemPrompt

        // 5. Call Gemini with image + tools (forces one tool call)
        let toolResult = try await geminiClient.sendImageToolRequest(
            prompt: prompt,
            imageData: jpegData,
            systemPrompt: currentSystemPrompt,
            tools: [tools],
            forceToolCall: true
        )

        guard let toolCall = toolResult.toolCalls.first else {
            log("Task: No tool call received, skipping")
            return nil
        }

        // 6a. Early exit: no task on screen — single API call, no search needed
        if toolCall.name == "no_task_found" {
            let contextSummary = toolCall.arguments["context_summary"] as? String ?? "No task on screen"
            let currentActivity = toolCall.arguments["current_activity"] as? String ?? "Unknown"
            log("Task: no_task_found — \(contextSummary)")
            return TaskExtractionResult(
                hasNewTask: false,
                task: nil,
                contextSummary: contextSummary,
                currentActivity: currentActivity
            )
        }

        // 6b. Potential task found — execute search
        guard toolCall.name == "search_similar_tasks",
              let query = toolCall.arguments["query"] as? String else {
            log("Task: Unexpected tool call: \(toolCall.name), skipping")
            return nil
        }

        log("Task: search_similar_tasks query: \"\(query)\"")
        let searchResults = await executeSearchTool(query: query)
        log("Task: Search returned \(searchResults.count) results")

        // 7. Encode search results for the prompt
        let searchResultsJson: String
        if let data = try? JSONEncoder().encode(searchResults),
           let json = String(data: data, encoding: .utf8) {
            searchResultsJson = json
        } else {
            searchResultsJson = "[]"
        }

        // 8. Choose path based on whether search found close matches
        let hasCloseMatches = searchResults.contains { ($0.similarity ?? 0) >= 0.5 }

        if hasCloseMatches {
            // PATH A: Close matches found — ask model to decide first (decision-only schema)
            return try await decisionThenExtract(
                query: query, appName: appName, searchResultsJson: searchResultsJson,
                systemPrompt: currentSystemPrompt
            )
        } else {
            // PATH B: No close matches — go straight to extraction (extraction-only schema)
            log("Task: No close matches, extracting directly")
            return try await extractTask(
                query: query, appName: appName, searchResultsJson: searchResultsJson,
                systemPrompt: currentSystemPrompt
            )
        }
    }

    // MARK: - Path A: Decision then optional extraction (close matches found)

    /// When search found close matches, first ask the model to decide if this is new or duplicate.
    /// If new, make a follow-up call to extract full task details.
    private func decisionThenExtract(
        query: String, appName: String, searchResultsJson: String, systemPrompt: String
    ) async throws -> TaskExtractionResult? {
        let decisionPrompt = """
        You analyzed a screenshot from \(appName) and identified a potential request: "\(query)"

        SEARCH RESULTS (existing tasks matching this request):
        \(searchResultsJson)

        Is this a genuinely NEW task, or is it already tracked / completed / rejected?

        Rules:
        - Similarity > 0.8 + status "active" → duplicate, set is_new_task to false
        - Status "completed" → already done, set is_new_task to false
        - Status "deleted" → user rejected this type of task, set is_new_task to false
        - Low similarity or different scope → genuinely new, set is_new_task to true
        """

        let decisionSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "is_new_task": .init(type: "boolean", description: "True only if this is genuinely new and not covered by any search result"),
                "reason": .init(type: "string", description: "Why this is or isn't a new task (e.g. 'duplicate of task #42' or 'different scope than existing tasks')"),
                "context_summary": .init(type: "string", description: "Brief summary of what user is looking at"),
                "current_activity": .init(type: "string", description: "What the user is actively doing")
            ],
            required: ["is_new_task", "reason", "context_summary", "current_activity"]
        )

        let decisionText = try await geminiClient.sendRequest(
            prompt: decisionPrompt,
            systemPrompt: systemPrompt,
            responseSchema: decisionSchema
        )

        let decision = try JSONDecoder().decode(TaskDecisionResult.self, from: Data(decisionText.utf8))
        log("Task: Decision — is_new_task: \(decision.isNewTask), reason: \(decision.reason)")

        guard decision.isNewTask else {
            return TaskExtractionResult(
                hasNewTask: false,
                task: nil,
                contextSummary: decision.contextSummary,
                currentActivity: decision.currentActivity
            )
        }

        // Decision says it's new — extract full task details
        return try await extractTask(
            query: query, appName: appName, searchResultsJson: searchResultsJson,
            systemPrompt: systemPrompt
        )
    }

    // MARK: - Path B / Follow-up: Extract task details (extraction-only schema)

    /// Extract full task details. All fields required, no ambiguity.
    private func extractTask(
        query: String, appName: String, searchResultsJson: String, systemPrompt: String
    ) async throws -> TaskExtractionResult {
        let extractionPrompt = """
        You analyzed a screenshot from \(appName) and identified this request: "\(query)"

        SEARCH RESULTS (for context, all non-duplicates):
        \(searchResultsJson)

        Extract the task details. Be specific: include WHO is asking and WHAT they want.
        - title: verb-first, ≤15 words, include the person/source and action
        - priority: "high" (urgent/today), "medium" (this week), "low" (no deadline)
        - confidence: 0.9+ explicit request, 0.7-0.9 clear implicit, 0.5-0.7 ambiguous
        - inferred_deadline: deadline if visible, otherwise empty string
        - description: additional context, otherwise empty string
        - source_category: where the task originated (direct_request, self_generated, calendar_driven, reactive, external_system, other)
        - source_subcategory: specific origin within that category
          direct_request → message, meeting, mention
          self_generated → idea, reminder, goal_subtask
          calendar_driven → event_prep, recurring, deadline
          reactive → error, notification, observation
          external_system → project_tool, alert, documentation
          any category → other
        """

        let extractionSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "title": .init(type: "string", description: "Brief, verb-first task title, ≤15 words. Include WHO and WHAT."),
                "description": .init(type: "string", description: "Additional context about the task. Empty string if none."),
                "priority": .init(type: "string", enum: ["high", "medium", "low"], description: "Task priority"),
                "tags": .init(
                    type: "array",
                    description: "1-3 relevant tags: feature, bug, code, work, personal, research, communication, finance, health, other",
                    items: .init(type: "string", properties: nil, required: nil)
                ),
                "source_app": .init(type: "string", description: "App where the task was found"),
                "inferred_deadline": .init(type: "string", description: "Deadline if visible or implied. Empty string if none."),
                "confidence": .init(type: "number", description: "Confidence score 0.0-1.0"),
                "context_summary": .init(type: "string", description: "Brief summary of what user is looking at"),
                "current_activity": .init(type: "string", description: "What the user is actively doing"),
                "source_category": .init(type: "string", enum: ["direct_request", "self_generated", "calendar_driven", "reactive", "external_system", "other"], description: "Where the task originated: direct_request (someone asked), self_generated (user's own idea/reminder), calendar_driven (calendar event), reactive (error/notification), external_system (tool/alert), other"),
                "source_subcategory": .init(type: "string", enum: ["message", "meeting", "mention", "idea", "reminder", "goal_subtask", "event_prep", "recurring", "deadline", "error", "notification", "observation", "project_tool", "alert", "documentation", "other"], description: "Specific origin: direct_request→message/meeting/mention, self_generated→idea/reminder/goal_subtask, calendar_driven→event_prep/recurring/deadline, reactive→error/notification/observation, external_system→project_tool/alert/documentation, any→other")
            ],
            required: ["title", "description", "priority", "tags", "source_app", "inferred_deadline", "confidence", "context_summary", "current_activity", "source_category", "source_subcategory"]
        )

        let extractionText = try await geminiClient.sendRequest(
            prompt: extractionPrompt,
            systemPrompt: systemPrompt,
            responseSchema: extractionSchema
        )

        let response = try JSONDecoder().decode(TaskExtractionResponse.self, from: Data(extractionText.utf8))
        log("Task: Extracted — \"\(response.title)\" (confidence: \(response.confidence), priority: \(response.priority))")
        return response.toExtractionResult()
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

    /// Execute search tool: combines vector similarity + FTS5 keyword search
    private func executeSearchTool(query: String) async -> [TaskSearchResult] {
        var resultMap: [Int64: TaskSearchResult] = [:]

        // Vector search
        do {
            let queryEmbedding = try await EmbeddingService.shared.embed(text: query)
            let vectorResults = await EmbeddingService.shared.searchSimilar(query: queryEmbedding, topK: 10)

            for result in vectorResults where result.similarity > 0.5 {
                // Look up the task description and status
                if let record = try await ActionItemStorage.shared.getActionItem(id: result.id) {
                    let status: String
                    if record.deleted { status = "deleted" }
                    else if record.completed { status = "completed" }
                    else { status = "active" }

                    resultMap[result.id] = TaskSearchResult(
                        id: result.id,
                        description: record.description,
                        status: status,
                        similarity: Double(result.similarity),
                        matchType: "vector"
                    )
                }
            }
        } catch {
            logError("Task: Vector search failed", error: error)
        }

        // FTS5 keyword search
        do {
            // Sanitize the query for FTS5 — use individual words with prefix matching
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

                    if var existing = resultMap[result.id] {
                        // Already found via vector — mark as "both"
                        existing = TaskSearchResult(
                            id: existing.id,
                            description: existing.description,
                            status: existing.status,
                            similarity: existing.similarity,
                            matchType: "both"
                        )
                        resultMap[result.id] = existing
                    } else {
                        resultMap[result.id] = TaskSearchResult(
                            id: result.id,
                            description: result.description,
                            status: status,
                            similarity: nil,
                            matchType: "fts"
                        )
                    }
                }
            }
        } catch {
            logError("Task: FTS search failed", error: error)
        }

        // Sort: vector matches first (highest similarity), then FTS-only
        return Array(resultMap.values).sorted { a, b in
            (a.similarity ?? 0) > (b.similarity ?? 0)
        }
    }
}
