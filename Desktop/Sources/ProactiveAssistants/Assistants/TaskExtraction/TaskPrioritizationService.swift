import Foundation

/// Service that scores AI-generated tasks once a day by relevance to the user's
/// profile and goals. Manual tasks are always shown. From AI tasks, only the
/// top 5 by relevance score are visible; the rest are hidden behind "Show more".
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

    /// In-memory cache of task relevance scores (task ID → score 0-100)
    private(set) var relevanceScores: [String: Int] = [:]

    /// Task IDs that should be hidden from default view
    private(set) var hiddenTaskIds: Set<String> = []

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

        // 1. Fetch incomplete tasks
        let tasks: [TaskActionItem]
        do {
            let response = try await APIClient.shared.getActionItems(limit: 200, completed: false)
            tasks = response.items
        } catch {
            log("TaskPrioritize: Failed to fetch tasks: \(error)")
            await notifyStoreUpdated()
            return
        }

        // Only AI-generated tasks need scoring — manual tasks are always shown
        let aiTasks = tasks.filter { $0.source != "manual" }

        guard aiTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: Only \(aiTasks.count) AI tasks, skipping (minimum: \(minimumTaskCount))")
            relevanceScores = [:]
            hiddenTaskIds = []
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

        // 3. Score only AI tasks with Gemini
        let scores = await scoreTasksWithGemini(
            tasks: aiTasks,
            profile: userProfile?.profileText,
            goals: goals,
            client: client
        )

        guard let scores = scores else {
            log("TaskPrioritize: Scoring failed, keeping all tasks visible")
            await notifyStoreUpdated()
            return
        }

        // 4. Update scores and determine which tasks to hide
        relevanceScores = scores

        // Manual tasks are never hidden — only AI-generated tasks get filtered.
        // From AI tasks, show the top N by score; hide the rest.
        let manualCount = tasks.count - aiTasks.count

        let sortedAI = aiTasks.sorted { a, b in
            (scores[a.id] ?? 50) > (scores[b.id] ?? 50)
        }

        let hiddenAI = sortedAI.dropFirst(defaultVisibleAICount)
        hiddenTaskIds = Set(hiddenAI.map { $0.id })

        let visibleCount = manualCount + min(aiTasks.count, defaultVisibleAICount)
        log("TaskPrioritize: Scored \(tasks.count) tasks (\(manualCount) manual, \(aiTasks.count) AI). Visible: \(visibleCount), Hidden: \(hiddenAI.count)")
        await notifyStoreUpdated()
    }

    private func scoreTasksWithGemini(
        tasks: [TaskActionItem],
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async -> [String: Int]? {

        // Build task descriptions
        let taskDescriptions = tasks.map { task -> String in
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

        let contextSection = contextParts.isEmpty ? "" : contextParts.joined(separator: "\n\n") + "\n\n"

        let prompt = """
        Score each task by relevance to this user. Consider:
        1. Alignment with the user's goals and current priorities
        2. Time urgency (due date proximity)
        3. Source reliability (manual tasks are highest priority, then transcription, then screenshot)
        4. Whether the task is actionable and specific vs. vague
        5. Real-world importance (financial, health, commitments to others)

        \(contextSection)TASKS TO SCORE:
        \(taskDescriptions)

        For each task, assign a relevance score from 0 to 100:
        - 90-100: Critical — directly tied to active goals, due soon, or user-created
        - 70-89: Important — relevant to user's work/life, actionable
        - 40-69: Moderate — somewhat relevant but not urgent
        - 0-39: Low — vague, not aligned with goals, or likely noise

        Be aggressive about scoring AI-generated tasks (screenshot/transcription source) lower \
        if they seem like noise or are not clearly actionable.
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
        let validIds = Set(tasks.map { $0.id })
        var scoresMap: [String: Int] = [:]

        for score in result.scores {
            guard validIds.contains(score.taskId) else {
                log("TaskPrioritize: Skipping unknown task_id '\(score.taskId)'")
                continue
            }
            scoresMap[score.taskId] = max(0, min(100, score.score))
        }

        return scoresMap
    }

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
