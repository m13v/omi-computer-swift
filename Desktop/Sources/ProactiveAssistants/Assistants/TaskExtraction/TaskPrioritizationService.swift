import Foundation

/// Service that scores AI-generated tasks by relevance to the user's profile,
/// goals, and task engagement history. Uses overlapping batches with Gemini 3 Pro
/// so each task is scored ~3 times for stability. Manual tasks are always shown.
/// From AI tasks, only the top 5 by averaged score are visible.
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
    private let batchSize = 50
    private let batchStepSize = 17  // ~3x overlap: each task appears in ceil(50/17) ≈ 3 batches

    /// In-memory cache of task relevance scores (task ID → averaged score 0-100)
    private(set) var relevanceScores: [String: Int] = [:]

    /// AI task IDs that are allowed to be visible (top N by averaged score)
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
        // Skip if already ran recently (within cooldown)
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

        // 1. Fetch all tasks from local SQLite
        let incompleteTasks: [TaskActionItem]
        let referenceTasks: [TaskActionItem]
        do {
            // All incomplete, non-deleted tasks
            incompleteTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 10000,
                completed: false
            )
            // Completed + deleted tasks as reference for user engagement patterns
            let completedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 100,
                completed: true
            )
            let deletedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 50,
                completed: nil,
                includeDeleted: true
            )
            // Only keep actually-deleted ones from the includeDeleted query
            let actuallyDeleted = deletedTasks.filter { task in
                // Tasks that are deleted but not in the incomplete set
                !incompleteTasks.contains(where: { $0.id == task.id }) &&
                !completedTasks.contains(where: { $0.id == task.id })
            }
            referenceTasks = completedTasks + actuallyDeleted
        } catch {
            log("TaskPrioritize: Failed to fetch tasks from SQLite: \(error)")
            await notifyStoreUpdated()
            return
        }

        // Only AI-generated tasks need scoring — manual tasks are always shown
        let aiTasks = incompleteTasks.filter { $0.source != "manual" }
        let manualCount = incompleteTasks.count - aiTasks.count

        guard aiTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: Only \(aiTasks.count) AI tasks, skipping (minimum: \(minimumTaskCount))")
            relevanceScores = [:]
            visibleAITaskIds = Set(aiTasks.map { $0.id })
            hasCompletedScoring = true
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
        let referenceContext = buildReferenceContext(referenceTasks)

        // 4. Score AI tasks in overlapping batches (~3x exposure per task)
        let averagedScores = await scoreInOverlappingBatches(
            aiTasks: aiTasks,
            referenceContext: referenceContext,
            profile: userProfile?.profileText,
            goals: goals,
            client: client
        )

        // 5. Update scores and build allowlist
        relevanceScores = averagedScores

        // Sort by score descending, take top N as visible allowlist
        let sortedByScore = aiTasks.sorted { a, b in
            (averagedScores[a.id] ?? 0) > (averagedScores[b.id] ?? 0)
        }
        visibleAITaskIds = Set(sortedByScore.prefix(defaultVisibleAICount).map { $0.id })
        hasCompletedScoring = true

        let hiddenCount = aiTasks.count - visibleAITaskIds.count
        log("TaskPrioritize: Scored \(aiTasks.count) AI tasks in batches (\(manualCount) manual always visible). Top \(visibleAITaskIds.count) AI visible, \(hiddenCount) hidden")
        await notifyStoreUpdated()
    }

    // MARK: - Overlapping Batch Scoring

    /// Score tasks in overlapping sliding-window batches so each task is seen ~3 times.
    /// Returns averaged scores across all appearances.
    private func scoreInOverlappingBatches(
        aiTasks: [TaskActionItem],
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async -> [String: Int] {
        // Build batches with overlap
        var batches: [[TaskActionItem]] = []
        var startIndex = 0

        while startIndex < aiTasks.count {
            let endIndex = min(startIndex + batchSize, aiTasks.count)
            let batch = Array(aiTasks[startIndex..<endIndex])
            batches.append(batch)
            startIndex += batchStepSize
            // If remaining tasks < batchStepSize, we've covered them in this batch
            if endIndex == aiTasks.count { break }
        }

        log("TaskPrioritize: Scoring \(aiTasks.count) AI tasks in \(batches.count) overlapping batches")

        // Score each batch sequentially (to avoid rate limits)
        var allScores: [String: [Int]] = [:]  // task ID → list of scores from each batch

        for (i, batch) in batches.enumerated() {
            log("TaskPrioritize: Scoring batch \(i + 1)/\(batches.count) (\(batch.count) tasks)")

            let batchScores = await scoreBatchWithGemini(
                batch: batch,
                referenceContext: referenceContext,
                profile: profile,
                goals: goals,
                client: client
            )

            if let scores = batchScores {
                for (taskId, score) in scores {
                    allScores[taskId, default: []].append(score)
                }
            } else {
                log("TaskPrioritize: Batch \(i + 1) failed, skipping")
            }
        }

        // Average scores across all appearances
        var averaged: [String: Int] = [:]
        for (taskId, scores) in allScores {
            let sum = scores.reduce(0, +)
            averaged[taskId] = sum / scores.count
        }

        return averaged
    }

    // MARK: - Single Batch Scoring

    private func scoreBatchWithGemini(
        batch: [TaskActionItem],
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

        let contextSection = contextParts.isEmpty ? "" : contextParts.joined(separator: "\n\n") + "\n\n"

        let prompt = """
        Score each task by relevance to this user. Consider:
        1. Alignment with the user's goals and current priorities
        2. Time urgency (due date proximity)
        3. Whether the task is actionable and specific vs. vague
        4. Real-world importance (financial, health, commitments to others)
        5. Similarity to tasks the user has completed or engaged with (see reference)

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
        should score above 70.
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

    // MARK: - Reference Context

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
