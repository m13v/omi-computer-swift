import Foundation

/// Service that periodically scores incomplete tasks by relevance to the user's
/// AI-generated profile and active goals. Tasks with low relevance are hidden
/// from the default view (top 5). Uses Gemini 3 Pro for scoring.
actor TaskPrioritizationService {
    static let shared = TaskPrioritizationService()

    private var geminiClient: GeminiClient?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private var lastRunTime: Date?

    // Configuration
    private let intervalSeconds: TimeInterval = 7200    // 2 hours
    private let startupDelaySeconds: TimeInterval = 90  // 90s delay at app launch
    private let cooldownSeconds: TimeInterval = 3600    // 1-hour cooldown
    private let minimumTaskCount = 2
    private let defaultVisibleCount = 5

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

        // 1. Fetch incomplete tasks
        let tasks: [TaskActionItem]
        do {
            let response = try await APIClient.shared.getActionItems(limit: 200, completed: false)
            tasks = response.items
        } catch {
            log("TaskPrioritize: Failed to fetch tasks: \(error)")
            return
        }

        guard tasks.count >= minimumTaskCount else {
            log("TaskPrioritize: Only \(tasks.count) tasks, skipping (minimum: \(minimumTaskCount))")
            // With very few tasks, show them all
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

        // 3. Build context and score tasks
        let scores = await scoreTasksWithGemini(
            tasks: tasks,
            profile: userProfile?.profileText,
            goals: goals,
            client: client
        )

        guard let scores = scores else {
            log("TaskPrioritize: Scoring failed, keeping all tasks visible")
            return
        }

        // 4. Update scores and determine which tasks to hide
        relevanceScores = scores

        // Determine hidden tasks: everything below top N by score,
        // but NEVER hide manual tasks or overdue tasks
        let now = Date()
        let sortedByScore = tasks.sorted { scoreA, scoreB in
            (scores[scoreA.id] ?? 50) > (scores[scoreB.id] ?? 50)
        }

        var visible = Set<String>()
        var hidden = Set<String>()

        for task in sortedByScore {
            let isManual = task.source == "manual"
            let isOverdue = task.dueAt.map { $0 < now } ?? false
            let isDueToday: Bool = {
                guard let due = task.dueAt else { return false }
                return Calendar.current.isDateInToday(due)
            }()

            // Always show manual, overdue, and due-today tasks
            if isManual || isOverdue || isDueToday {
                visible.insert(task.id)
            } else if visible.count < defaultVisibleCount {
                visible.insert(task.id)
            } else {
                hidden.insert(task.id)
            }
        }

        hiddenTaskIds = hidden

        log("TaskPrioritize: Scored \(tasks.count) tasks. Visible: \(visible.count), Hidden: \(hidden.count)")
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

    /// Notify TasksStore that prioritization scores have been updated
    private func notifyStoreUpdated() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .taskPrioritizationDidUpdate, object: nil)
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
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
