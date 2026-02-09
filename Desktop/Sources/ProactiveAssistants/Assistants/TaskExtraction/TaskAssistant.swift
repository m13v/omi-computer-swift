import Foundation

/// Task extraction assistant that identifies tasks and action items from screen content
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

    // Cache for validation context (refreshed periodically)
    private var cachedExistingTasks: [String] = []
    private var cachedMemories: [String] = []
    private var lastContextRefresh: Date = .distantPast
    private let contextRefreshInterval: TimeInterval = 300 // Refresh every 5 minutes

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

        // Start processing loop
        Task {
            await self.startProcessing()
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
        // Task assistant analyzes less frequently - every N seconds
        // The actual interval is checked in the processing loop
        // Here we just accept frames to store the latest one
        return true
    }

    func analyze(frame: CapturedFrame) async -> AssistantResult? {
        // Skip apps excluded from task extraction
        let excluded = await MainActor.run { TaskAssistantSettings.shared.isAppExcluded(frame.appName) }
        if excluded {
            log("Task: Skipping excluded app '\(frame.appName)'")
            return nil
        }

        // Store the latest frame - we'll process it when the interval has passed
        let hadPending = pendingFrame != nil
        pendingFrame = frame
        if !hadPending {
            log("Task: Received frame from \(frame.appName), queued for analysis")
        }
        // Signal the processing loop that a frame is available
        frameSignalContinuation.yield()
        return nil
    }

    func handleResult(_ result: AssistantResult, sendEvent: @escaping (String, [String: Any]) -> Void) async {
        // This method is required by protocol but we use handleResultWithScreenshot instead
        guard let taskResult = result as? TaskExtractionResult else { return }
        await handleResultWithScreenshot(taskResult, screenshotId: nil, sendEvent: sendEvent)
    }

    /// Handle result with screenshot ID for SQLite storage
    private func handleResultWithScreenshot(
        _ taskResult: TaskExtractionResult,
        screenshotId: Int64?,
        sendEvent: @escaping (String, [String: Any]) -> Void
    ) async {
        // Check if AI found a new task
        guard taskResult.hasNewTask, let task = taskResult.task else {
            return
        }

        // Get min confidence threshold
        let threshold = await minConfidence
        let confidencePercent = Int(task.confidence * 100)

        // Check confidence threshold
        guard task.confidence >= threshold else {
            log("Task: [\(confidencePercent)% < \(Int(threshold * 100))%] Filtered: \"\(task.title)\"")
            return
        }

        log("Task: [\(confidencePercent)% conf.] \"\(task.title)\"")

        // Add to previous tasks (keep last 10 for context)
        previousTasks.insert(task, at: 0)
        if previousTasks.count > maxPreviousTasks {
            previousTasks.removeLast()
        }

        // Save to SQLite first
        let extractionRecord = await saveTaskToSQLite(
            task: task,
            screenshotId: screenshotId,
            contextSummary: taskResult.contextSummary
        )

        // Sync to backend
        if let backendId = await syncTaskToBackend(task: task, taskResult: taskResult) {
            // Update SQLite record with backend ID
            if let recordId = extractionRecord?.id {
                do {
                    try await ActionItemStorage.shared.markSynced(id: recordId, backendId: backendId)
                } catch {
                    logError("Task: Failed to update sync status", error: error)
                }
            }
        }

        // Track task extracted
        await MainActor.run {
            AnalyticsManager.shared.taskExtracted(taskCount: 1)
        }

        // Send notification
        await sendTaskNotification(task: task)

        // Send event to Flutter
        sendEvent("taskExtracted", [
            "assistant": identifier,
            "task": task.toDictionary(),
            "contextSummary": taskResult.contextSummary
        ])
    }

    /// Save extracted task to SQLite using ActionItemStorage
    private func saveTaskToSQLite(
        task: ExtractedTask,
        screenshotId: Int64?,
        contextSummary: String
    ) async -> ActionItemRecord? {
        // Build metadata JSON with extraction details
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

        // Build tagsJson
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

            // Add reasoning/description if available
            if let reasoning = task.description {
                metadata["reasoning"] = reasoning
            }

            // Add inferred deadline if available
            if let deadline = task.inferredDeadline {
                metadata["inferred_deadline"] = deadline
            }

            let response = try await APIClient.shared.createActionItem(
                description: task.title,
                dueAt: nil, // Could parse task.inferredDeadline if available
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

        // Send notification immediately (extraction interval already throttles)
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
            // Don't clear previous tasks on app switch - we want to track across apps
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

    // MARK: - Analysis

    private func processFrame(_ frame: CapturedFrame) async {
        let enabled = await isEnabled
        guard enabled else {
            log("Task: Skipping analysis (disabled)")
            return
        }

        log("Task: Analyzing frame from \(frame.appName)...")
        do {
            guard let result = try await extractTasks(from: frame.jpegData, appName: frame.appName) else {
                log("Task: Analysis returned no result")
                return
            }

            log("Task: Analysis complete - hasNewTask: \(result.hasNewTask), context: \(result.contextSummary)")

            // Stage 1: Log draft task and validate
            var finalResult = result
            if result.hasNewTask, let task = result.task {
                let confidencePercent = Int(task.confidence * 100)
                log("Task: [DRAFT] [\(confidencePercent)%] \"\(task.title)\"")

                // Stage 2: Validate the draft task against existing context
                let validationResult = await validateDraftTask(task: task, contextSummary: result.contextSummary)
                log("Task: [FINAL] \(validationResult.isValid ? "APPROVED" : "REJECTED") - \"\(task.title)\" - \(validationResult.reason)")

                // If validation rejects the task, override to no-task result
                if !validationResult.isValid {
                    finalResult = TaskExtractionResult(
                        hasNewTask: false,
                        task: nil,
                        contextSummary: result.contextSummary,
                        currentActivity: result.currentActivity
                    )
                }
            }

            // Handle the result with screenshot ID for SQLite storage
            await handleResultWithScreenshot(finalResult, screenshotId: frame.screenshotId) { type, data in
                Task { @MainActor in
                    AssistantCoordinator.shared.sendEvent(type: type, data: data)
                }
            }
        } catch {
            logError("Task extraction error", error: error)
        }
    }

    private func extractTasks(from jpegData: Data, appName: String) async throws -> TaskExtractionResult? {
        // Build context with previous tasks
        var prompt = "Screenshot from \(appName). Is there a request directed at the user from another person or AI that they haven't acted on? If yes, assign 1-3 relevant tags (e.g. a coding work task could have tags ['work', 'code']).\n\n"

        if !previousTasks.isEmpty {
            prompt += "PREVIOUSLY EXTRACTED TASKS (do not re-extract these or semantically similar ones):\n"
            for (index, task) in previousTasks.enumerated() {
                prompt += "\(index + 1). \(task.title)"
                if let description = task.description {
                    prompt += " - \(description)"
                }
                prompt += "\n"
            }
            prompt += "\nOnly extract a NEW request not already covered above."
        } else {
            prompt += "Is there an unaddressed request from someone?"
        }

        // Get current system prompt from settings
        let currentSystemPrompt = await systemPrompt

        // Build response schema for single task extraction with conditional logic
        let taskProperties: [String: GeminiRequest.GenerationConfig.ResponseSchema.Property] = [
            "title": .init(type: "string", description: "Brief, actionable task title"),
            "description": .init(type: "string", description: "Optional additional context"),
            "priority": .init(type: "string", enum: ["high", "medium", "low"], description: "Task priority"),
            "tags": .init(
                type: "array",
                description: "1-3 relevant tags from: 'feature' (new features/enhancements), 'bug' (bugs/issues), 'code' (coding/development), 'work' (professional), 'personal' (personal to-dos), 'research' (investigation/learning), 'communication' (messages/calls), 'finance' (money-related), 'health' (wellness), 'other' (everything else). A task can have multiple tags e.g. ['work', 'code'].",
                items: .init(type: "string", properties: nil, required: nil)
            ),
            "source_app": .init(type: "string", description: "App where task was found"),
            "inferred_deadline": .init(type: "string", description: "Deadline if visible or implied"),
            "confidence": .init(type: "number", description: "Confidence score 0.0-1.0")
        ]

        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "has_new_task": .init(type: "boolean", description: "True if a new task was found that is not in the previous tasks list"),
                "task": .init(
                    type: "object",
                    description: "The extracted task (only if has_new_task is true)",
                    properties: taskProperties,
                    required: ["title", "priority", "tags", "source_app", "confidence"]
                ),
                "context_summary": .init(type: "string", description: "Brief summary of what user is looking at"),
                "current_activity": .init(type: "string", description: "High-level description of user's activity")
            ],
            required: ["has_new_task", "context_summary", "current_activity"]
        )

        do {
            let responseText = try await geminiClient.sendRequest(
                prompt: prompt,
                imageData: jpegData,
                systemPrompt: currentSystemPrompt,
                responseSchema: responseSchema
            )

            return try JSONDecoder().decode(TaskExtractionResult.self, from: Data(responseText.utf8))
        } catch {
            logError("Task analysis error", error: error)
            return nil
        }
    }

    // MARK: - Two-Stage Validation

    /// Result of task validation against existing context
    private struct ValidationResult {
        let isValid: Bool
        let reason: String
        let adjustedConfidence: Double?
    }

    /// Validate a draft task against existing tasks and memories
    private func validateDraftTask(task: ExtractedTask, contextSummary: String) async -> ValidationResult {
        // Refresh context if needed
        await refreshValidationContext()

        // Build validation prompt
        let validationPrompt = buildValidationPrompt(task: task, contextSummary: contextSummary)

        // For now, use text-only validation (no image needed)
        do {
            let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
                type: "object",
                properties: [
                    "is_valid": .init(type: "boolean", description: "True if the task should be kept, false if it should be filtered out"),
                    "reason": .init(type: "string", description: "Brief explanation of why the task is valid or invalid"),
                    "adjusted_confidence": .init(type: "number", description: "Adjusted confidence score 0.0-1.0 based on context validation")
                ],
                required: ["is_valid", "reason"]
            )

            let responseText = try await geminiClient.sendRequest(
                prompt: validationPrompt,
                systemPrompt: validationSystemPrompt,
                responseSchema: responseSchema
            )

            // Parse response
            struct ValidationResponse: Codable {
                let isValid: Bool
                let reason: String
                let adjustedConfidence: Double?

                enum CodingKeys: String, CodingKey {
                    case isValid = "is_valid"
                    case reason
                    case adjustedConfidence = "adjusted_confidence"
                }
            }

            let response = try JSONDecoder().decode(ValidationResponse.self, from: Data(responseText.utf8))
            return ValidationResult(
                isValid: response.isValid,
                reason: response.reason,
                adjustedConfidence: response.adjustedConfidence
            )
        } catch {
            logError("Task validation error", error: error)
            // On error, default to valid to not block tasks
            return ValidationResult(isValid: true, reason: "Validation skipped (error)", adjustedConfidence: nil)
        }
    }

    /// Refresh cached validation context (existing tasks and memories) from local SQLite
    private func refreshValidationContext() async {
        let timeSinceLastRefresh = Date().timeIntervalSince(lastContextRefresh)
        guard timeSinceLastRefresh >= contextRefreshInterval else {
            return
        }

        log("Task: Refreshing validation context...")
        lastContextRefresh = Date()

        // Fetch existing tasks from local SQLite (action_items table)
        do {
            let localTasks = try await ActionItemStorage.shared.getLocalActionItems(limit: 50, completed: false)
            cachedExistingTasks = localTasks.map { $0.description }
            log("Task: Loaded \(localTasks.count) local tasks for validation")
        } catch {
            logError("Task: Failed to load local tasks", error: error)
        }

        // Fetch recent memories from local SQLite
        do {
            let memories = try await MemoryStorage.shared.getLocalMemories(limit: 30)
            cachedMemories = memories.map { $0.content }
            log("Task: Loaded \(memories.count) memories for validation")
        } catch {
            logError("Task: Failed to load memories", error: error)
        }
    }

    /// Build the validation prompt with context
    private func buildValidationPrompt(task: ExtractedTask, contextSummary: String) -> String {
        var prompt = """
        DRAFT TASK TO VALIDATE:
        Title: \(task.title)
        Priority: \(task.priority.rawValue)
        Confidence: \(Int(task.confidence * 100))%
        Source App: \(task.sourceApp)
        Context: \(contextSummary)
        """

        if let description = task.description {
            prompt += "\nDescription: \(description)"
        }
        if let deadline = task.inferredDeadline {
            prompt += "\nInferred Deadline: \(deadline)"
        }

        prompt += "\n\n"

        // Add existing tasks
        if !cachedExistingTasks.isEmpty {
            prompt += "EXISTING TASKS THE USER IS ALREADY TRACKING:\n"
            for (index, existingTask) in cachedExistingTasks.prefix(30).enumerated() {
                prompt += "\(index + 1). \(existingTask)\n"
            }
            prompt += "\n"
        }

        // Add memories for context about user's priorities
        if !cachedMemories.isEmpty {
            prompt += "USER'S MEMORIES (for understanding priorities and context):\n"
            for (index, memory) in cachedMemories.prefix(20).enumerated() {
                prompt += "\(index + 1). \(memory)\n"
            }
            prompt += "\n"
        }

        prompt += """

        Based on the above context, determine if this draft task should be kept or filtered out.
        """

        return prompt
    }

    /// System prompt for task validation
    private var validationSystemPrompt: String {
        """
        You validate whether an extracted task is actually a request from another person or AI that the user needs to act on.

        REJECT (is_valid = false) if:
        1. It's NOT a request from someone — it's just something the user is doing or looking at
        2. It's a development/terminal task (build errors, package updates, code changes)
        3. It's semantically similar to an existing task already being tracked
        4. It's too vague to act on ("Check things", "Follow up")
        5. The user already responded to or completed the request
        6. It's a notification badge without a specific actionable message

        APPROVE (is_valid = true) if:
        1. It's a clear request from a person or AI that the user hasn't addressed
        2. It's the user's own explicit reminder ("TODO", "Remind me to…", "Don't forget")
        3. It's genuinely new — not already tracked in existing tasks
        4. The user would likely forget it after switching windows

        Adjust confidence based on context. Be concise — one short sentence for your reason.
        """
    }
}
