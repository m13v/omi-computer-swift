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
        await handleResultWithScreenshot(taskResult, screenshotId: nil, sendEvent: sendEvent)
    }

    /// Handle result with screenshot ID for SQLite storage
    private func handleResultWithScreenshot(
        _ taskResult: TaskExtractionResult,
        screenshotId: Int64?,
        sendEvent: @escaping (String, [String: Any]) -> Void
    ) async {
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
            "context_summary": contextSummary
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
                "tags": task.tags
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

            await handleResultWithScreenshot(result, screenshotId: frame.screenshotId) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("Task extraction error", error: error)
        }
    }

    /// Single-stage extraction: image analysis + tool call for search + final decision
    private func extractTaskSingleStage(from jpegData: Data, appName: String) async throws -> TaskExtractionResult? {
        // 1. Gather context
        let context = await refreshContext()

        // 2. Build prompt with injected context
        var prompt = "Screenshot from \(appName). Analyze this screenshot for any unaddressed request directed at the user.\n\n"

        // Inject active tasks
        if !context.activeTasks.isEmpty {
            prompt += "ACTIVE TASKS (user is already tracking these):\n"
            for (i, task) in context.activeTasks.enumerated() {
                let pri = task.priority.map { " [\($0)]" } ?? ""
                prompt += "\(i + 1). \(task.description)\(pri)\n"
            }
            prompt += "\n"
        }

        // Inject completed tasks
        if !context.completedTasks.isEmpty {
            prompt += "RECENTLY COMPLETED (user already did these):\n"
            for (i, task) in context.completedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        // Inject user-deleted tasks
        if !context.deletedTasks.isEmpty {
            prompt += "USER-DELETED TASKS (user explicitly rejected these — do not re-extract similar):\n"
            for (i, task) in context.deletedTasks.enumerated() {
                prompt += "\(i + 1). \(task.description)\n"
            }
            prompt += "\n"
        }

        // Inject goals
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

        prompt += "If you see a potential request, you MUST call search_similar_tasks before deciding."

        // 3. Define the search tool
        let searchTool = GeminiTool(functionDeclarations: [
            GeminiTool.FunctionDeclaration(
                name: "search_similar_tasks",
                description: "Search for existing tasks similar to a potential new task. MUST be called before deciding whether to extract a task. Returns matching tasks from vector similarity and keyword search.",
                parameters: GeminiTool.FunctionDeclaration.Parameters(
                    type: "object",
                    properties: [
                        "query": .init(type: "string", description: "A concise description of the potential task to search for")
                    ],
                    required: ["query"]
                )
            )
        ])

        // 4. Get system prompt
        let currentSystemPrompt = await systemPrompt

        // 5. Call Gemini with image + tools (forces tool call)
        let toolResult = try await geminiClient.sendImageToolRequest(
            prompt: prompt,
            imageData: jpegData,
            systemPrompt: currentSystemPrompt,
            tools: [searchTool],
            forceToolCall: true
        )

        // 6. Execute search tool locally
        guard let toolCall = toolResult.toolCalls.first,
              toolCall.name == "search_similar_tasks",
              let query = toolCall.arguments["query"] as? String else {
            log("Task: No search_similar_tasks call received, skipping")
            return nil
        }

        log("Task: search_similar_tasks query: \"\(query)\"")
        let searchResults = await executeSearchTool(query: query)
        log("Task: Search returned \(searchResults.count) results")

        // 7. Continue with search results — model returns final JSON
        let searchResultsJson: String
        if let data = try? JSONEncoder().encode(searchResults),
           let json = String(data: data, encoding: .utf8) {
            searchResultsJson = json
        } else {
            searchResultsJson = "[]"
        }

        let responseText = try await geminiClient.continueImageToolRequest(
            originalPrompt: prompt,
            originalImageData: jpegData,
            toolCall: toolCall,
            toolResult: searchResultsJson,
            systemPrompt: currentSystemPrompt
        )

        // 8. Parse JSON response
        // Strip markdown code fences if present
        var cleanedResponse = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedResponse.hasPrefix("```json") {
            cleanedResponse = String(cleanedResponse.dropFirst(7))
        } else if cleanedResponse.hasPrefix("```") {
            cleanedResponse = String(cleanedResponse.dropFirst(3))
        }
        if cleanedResponse.hasSuffix("```") {
            cleanedResponse = String(cleanedResponse.dropLast(3))
        }
        cleanedResponse = cleanedResponse.trimmingCharacters(in: .whitespacesAndNewlines)

        return try JSONDecoder().decode(TaskExtractionResult.self, from: Data(cleanedResponse.utf8))
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
