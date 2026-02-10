import Foundation

/// Service that scores AI-generated tasks by relevance to the user's profile,
/// goals, and task engagement history. Uses overlapping batches with Gemini 3 Pro
/// where each batch includes previously-scored anchor tasks for calibration.
/// Scores are persisted to SQLite. Manual tasks are always shown.
/// From AI tasks, only the top 5 by score are visible.
actor TaskPrioritizationService {
    static let shared = TaskPrioritizationService()

    private var geminiClient: GeminiClient?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private var lastRunTime: Date?

    // Configuration
    private let intervalSeconds: TimeInterval = 86400   // 24 hours (once a day)
    private let startupDelaySeconds: TimeInterval = 90  // 90s delay at app launch
    private let cooldownSeconds: TimeInterval = 43200   // 12-hour cooldown
    private let minimumTaskCount = 2
    private let defaultVisibleAICount = 5
    private let batchSize = 250
    private let batchStepSize = 200  // 50-task overlap between consecutive batches

    /// AI task IDs that are allowed to be visible (top N by score)
    private(set) var visibleAITaskIds: Set<String> = []

    /// Whether prioritization has completed at least once
    private(set) var hasCompletedScoring = false

    private init() {
        do {
            self.geminiClient = try GeminiClient(model: "gemini-3-pro-preview")
        } catch {
            log("TaskPrioritize: Failed to initialize GeminiClient: \(error)")
            self.geminiClient = nil
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        log("TaskPrioritize: Service started")

        timer = Task { [weak self] in
            // Startup delay
            try? await Task.sleep(nanoseconds: UInt64(90 * 1_000_000_000))

            while !Task.isCancelled {
                guard let self = self else { break }

                // Check cooldown
                if let lastRun = await self.lastRunTime,
                   Date().timeIntervalSince(lastRun) < self.cooldownSeconds {
                    let remaining = self.cooldownSeconds - Date().timeIntervalSince(lastRun)
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    continue
                }

                await self.runPrioritization()

                // Wait for next interval
                try? await Task.sleep(nanoseconds: UInt64(self.intervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        timer?.cancel()
        timer = nil
        isRunning = false
        log("TaskPrioritize: Service stopped")
    }

    /// Force a re-prioritization (e.g. when user opens Tasks tab)
    func runIfNeeded() async {
        // If we have persisted scores, load the allowlist immediately
        if !hasCompletedScoring {
            await loadAllowlistFromSQLite()
        }

        // Skip full scoring if already ran recently (within cooldown)
        if let lastRun = lastRunTime,
           Date().timeIntervalSince(lastRun) < cooldownSeconds {
            return
        }
        await runPrioritization()
    }

    // MARK: - Prioritization Logic

    private func runPrioritization() async {
        guard let client = geminiClient else {
            log("TaskPrioritize: Skipping - Gemini client not initialized")
            return
        }

        lastRunTime = Date()
        log("TaskPrioritize: Starting prioritization run")
        await notifyStoreStarted()

        // 1. Load already-scored AI tasks from SQLite (these are our anchors)
        let scoredTasks: [TaskActionItem]
        let unscoredTasks: [TaskActionItem]
        do {
            scoredTasks = try await ActionItemStorage.shared.getScoredAITasks()
            unscoredTasks = try await ActionItemStorage.shared.getUnscoredAITasks()
        } catch {
            log("TaskPrioritize: Failed to fetch tasks from SQLite: \(error)")
            await notifyStoreUpdated()
            return
        }

        log("TaskPrioritize: Found \(scoredTasks.count) already-scored, \(unscoredTasks.count) unscored AI tasks")

        guard unscoredTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: Only \(unscoredTasks.count) unscored tasks, refreshing allowlist from existing scores")
            await loadAllowlistFromSQLite()
            await notifyStoreUpdated()
            return
        }

        // 2. Fetch user profile and goals
        let userProfile = await AIUserProfileService.shared.getLatestProfile()
        let goals: [Goal]
        do {
            goals = try await APIClient.shared.getGoals()
        } catch {
            log("TaskPrioritize: Failed to fetch goals: \(error)")
            goals = []
        }

        // 3. Build reference context (completed/deleted tasks the user engaged with)
        let referenceTasks: [TaskActionItem]
        do {
            let completedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 100,
                completed: true
            )
            referenceTasks = completedTasks
        } catch {
            log("TaskPrioritize: Failed to fetch reference tasks: \(error)")
            referenceTasks = []
        }
        let referenceContext = buildReferenceContext(referenceTasks)

        // 4. Build anchor context from already-scored tasks (top + bottom for range calibration)
        let anchorContext = buildAnchorContext(scoredTasks)

        // 5. Score unscored tasks in overlapping batches, with anchors for calibration
        await scoreInBatches(
            unscoredTasks: unscoredTasks,
            anchorContext: anchorContext,
            referenceContext: referenceContext,
            profile: userProfile?.profileText,
            goals: goals,
            client: client
        )

        // 6. Reload allowlist from SQLite (now includes newly scored tasks)
        await loadAllowlistFromSQLite()

        let totalAI = scoredTasks.count + unscoredTasks.count
        log("TaskPrioritize: Done. \(totalAI) total AI tasks. Top \(visibleAITaskIds.count) visible.")
        await notifyStoreUpdated()
    }

    // MARK: - Allowlist from SQLite

    /// Load the top N scored AI tasks from SQLite and set them as the visible allowlist
    private func loadAllowlistFromSQLite() async {
        do {
            let topTasks = try await ActionItemStorage.shared.getScoredAITasks(
                limit: defaultVisibleAICount
            )
            visibleAITaskIds = Set(topTasks.map { $0.id })
            hasCompletedScoring = true
            log("TaskPrioritize: Loaded allowlist from SQLite — \(visibleAITaskIds.count) AI tasks visible")
        } catch {
            log("TaskPrioritize: Failed to load allowlist from SQLite: \(error)")
        }
    }

    // MARK: - Batch Scoring

    /// Score unscored tasks in overlapping batches. Each batch includes anchor tasks
    /// (previously-scored) so the model can calibrate scores across the full range.
    private func scoreInBatches(
        unscoredTasks: [TaskActionItem],
        anchorContext: String,
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async {
        // Build overlapping batches
        var batches: [[TaskActionItem]] = []
        var startIndex = 0

        while startIndex < unscoredTasks.count {
            let endIndex = min(startIndex + batchSize, unscoredTasks.count)
            let batch = Array(unscoredTasks[startIndex..<endIndex])
            batches.append(batch)
            startIndex += batchStepSize
            if endIndex == unscoredTasks.count { break }
        }

        log("TaskPrioritize: Scoring \(unscoredTasks.count) unscored tasks in \(batches.count) batches")

        for (i, batch) in batches.enumerated() {
            log("TaskPrioritize: Scoring batch \(i + 1)/\(batches.count) (\(batch.count) tasks)")

            let batchScores = await scoreBatchWithGemini(
                batch: batch,
                anchorContext: anchorContext,
                referenceContext: referenceContext,
                profile: profile,
                goals: goals,
                client: client
            )

            guard let scores = batchScores else {
                log("TaskPrioritize: Batch \(i + 1) failed, skipping")
                continue
            }

            // Persist scores to SQLite immediately after each batch
            do {
                try await ActionItemStorage.shared.updateRelevanceScores(scores)
                log("TaskPrioritize: Batch \(i + 1) persisted \(scores.count) scores")
            } catch {
                log("TaskPrioritize: Failed to persist batch \(i + 1) scores: \(error)")
            }
        }
    }

    // MARK: - Single Batch Scoring

    private func scoreBatchWithGemini(
        batch: [TaskActionItem],
        anchorContext: String,
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async -> [String: Int]? {

        // Build task descriptions for this batch
        let taskDescriptions = batch.map { task -> String in
            var parts = ["ID: \(task.id)", "Description: \(task.description)"]
            if let due = task.dueAt {
                parts.append("Due: \(ISO8601DateFormatter().string(from: due))")
            }
            if let priority = task.priority {
                parts.append("Priority: \(priority)")
            }
            if let source = task.source {
                parts.append("Source: \(source)")
            }
            parts.append("Created: \(ISO8601DateFormatter().string(from: task.createdAt))")
            return parts.joined(separator: " | ")
        }.joined(separator: "\n")

        // Build context sections
        var contextParts: [String] = []

        if let profile = profile, !profile.isEmpty {
            contextParts.append("USER PROFILE:\n\(profile)")
        }

        if !goals.isEmpty {
            let goalsText = goals.enumerated().map { (i, goal) in
                var text = "\(i + 1). \(goal.title)"
                if let desc = goal.description {
                    text += " — \(desc)"
                }
                text += " (\(Int(goal.progress))% complete)"
                return text
            }.joined(separator: "\n")
            contextParts.append("ACTIVE GOALS:\n\(goalsText)")
        }

        if !referenceContext.isEmpty {
            contextParts.append(referenceContext)
        }

        if !anchorContext.isEmpty {
            contextParts.append(anchorContext)
        }

        let contextSection = contextParts.isEmpty ? "" : contextParts.joined(separator: "\n\n") + "\n\n"

        let prompt = """
        Score each task by relevance to this user. Consider:
        1. Alignment with the user's goals and current priorities
        2. Time urgency (due date proximity)
        3. Whether the task is actionable and specific vs. vague
        4. Real-world importance (financial, health, commitments to others)
        5. Similarity to tasks the user has completed or engaged with (see reference)

        Use the ANCHOR TASKS (already scored) to calibrate your scoring — place new tasks \
        relative to those anchors on the same 0-100 scale.

        \(contextSection)TASKS TO SCORE:
        \(taskDescriptions)

        For each task, assign a relevance score from 0 to 100:
        - 90-100: Critical — directly tied to active goals, due soon, clearly actionable
        - 70-89: Important — relevant to user's work/life, actionable
        - 40-69: Moderate — somewhat relevant but not urgent
        - 0-39: Low — vague, not aligned with goals, or likely noise

        Be aggressive about scoring lower if tasks seem like noise or are not clearly actionable.
        """

        let systemPrompt = """
        You are a task prioritization assistant. You score tasks by relevance to the user's \
        profile, goals, and priorities. Be decisive — most AI-extracted tasks are noise and \
        should score below 50. Only tasks that are clearly important to this specific user \
        should score above 70. Use the anchor tasks to maintain consistent scoring across batches.
        """

        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "scores": .init(
                    type: "array",
                    description: "Relevance score for each task",
                    items: .init(
                        type: "object",
                        properties: [
                            "task_id": .init(type: "string", description: "The task ID"),
                            "score": .init(type: "integer", description: "Relevance score 0-100"),
                            "reason": .init(type: "string", description: "Brief reason for the score")
                        ],
                        required: ["task_id", "score", "reason"]
                    )
                )
            ],
            required: ["scores"]
        )

        let responseText: String
        do {
            responseText = try await client.sendRequest(
                prompt: prompt,
                systemPrompt: systemPrompt,
                responseSchema: responseSchema
            )
        } catch {
            log("TaskPrioritize: Gemini request failed: \(error)")
            return nil
        }

        guard let data = responseText.data(using: .utf8) else {
            log("TaskPrioritize: Failed to convert response to data")
            return nil
        }

        let result: PrioritizationResponse
        do {
            result = try JSONDecoder().decode(PrioritizationResponse.self, from: data)
        } catch {
            log("TaskPrioritize: Failed to parse response: \(error)")
            return nil
        }

        // Build scores map, validate IDs
        let validIds = Set(batch.map { $0.id })
        var scoresMap: [String: Int] = [:]

        for score in result.scores {
            guard validIds.contains(score.taskId) else { continue }
            scoresMap[score.taskId] = max(0, min(100, score.score))
        }

        return scoresMap
    }

    // MARK: - Context Builders

    /// Build anchor context from already-scored tasks for calibration.
    /// Includes a sample of high, medium, and low scored tasks so the model
    /// understands the full range.
    private func buildAnchorContext(_ scoredTasks: [TaskActionItem]) -> String {
        guard !scoredTasks.isEmpty else { return "" }

        // scoredTasks are already sorted by score descending (from getScoredAITasks)
        // Pick anchors from top, middle, and bottom of the range
        var anchors: [(TaskActionItem, Int)] = []

        // Top 5
        for task in scoredTasks.prefix(5) {
            if let score = task.relevanceScore {
                anchors.append((task, score))
            }
        }

        // Middle 5
        if scoredTasks.count > 15 {
            let midStart = scoredTasks.count / 2 - 2
            for task in scoredTasks[midStart..<min(midStart + 5, scoredTasks.count)] {
                if let score = task.relevanceScore {
                    anchors.append((task, score))
                }
            }
        }

        // Bottom 5
        if scoredTasks.count > 10 {
            for task in scoredTasks.suffix(5) {
                if let score = task.relevanceScore {
                    anchors.append((task, score))
                }
            }
        }

        guard !anchors.isEmpty else { return "" }

        let lines = anchors.map { (task, score) in
            "- [Score: \(score)] \(task.description)"
        }.joined(separator: "\n")

        return "ANCHOR TASKS (already scored — use these to calibrate your scoring scale):\n\(lines)"
    }

    /// Build a context string from completed/deleted tasks showing what the user engages with
    private func buildReferenceContext(_ tasks: [TaskActionItem]) -> String {
        guard !tasks.isEmpty else { return "" }

        let completed = tasks.filter { !($0.description.isEmpty) }.prefix(50)
        guard !completed.isEmpty else { return "" }

        let lines = completed.map { task -> String in
            let status = task.completed ? "completed" : "deleted"
            return "- [\(status)] \(task.description)"
        }.joined(separator: "\n")

        return "TASKS THE USER HAS ENGAGED WITH (for reference — do NOT score these):\n\(lines)"
    }

    // MARK: - Notifications

    /// Notify TasksStore that prioritization has started
    private func notifyStoreStarted() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .taskPrioritizationDidStart, object: nil)
        }
    }

    /// Notify TasksStore that prioritization scores have been updated (or finished)
    private func notifyStoreUpdated() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .taskPrioritizationDidUpdate, object: nil)
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let taskPrioritizationDidStart = Notification.Name("taskPrioritizationDidStart")
    static let taskPrioritizationDidUpdate = Notification.Name("taskPrioritizationDidUpdate")
}

// MARK: - Response Models

private struct PrioritizationResponse: Codable {
    let scores: [TaskScore]

    struct TaskScore: Codable {
        let taskId: String
        let score: Int
        let reason: String

        enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
            case score
            case reason
        }
    }
}
