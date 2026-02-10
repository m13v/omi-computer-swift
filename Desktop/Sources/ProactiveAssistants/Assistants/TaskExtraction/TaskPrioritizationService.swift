import Foundation

/// Service that re-ranks AI-generated tasks by relevance to the user's profile,
/// goals, and task engagement history. Once daily, sends ALL active tasks to Gemini
/// and receives back ONLY the tasks that need re-ranking with their new positions.
/// Those tasks are inserted at their new positions; all others shift to accommodate.
/// Scores are persisted to SQLite. Manual tasks are always shown.
actor TaskPrioritizationService {
    static let shared = TaskPrioritizationService()

    private var geminiClient: GeminiClient?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private(set) var isScoringInProgress = false

    // Persisted to UserDefaults so they survive app restarts
    private static let fullRunKey = "TaskPrioritize.lastFullRunTime"

    private var lastFullRunTime: Date? {
        didSet { UserDefaults.standard.set(lastFullRunTime, forKey: Self.fullRunKey) }
    }

    // Configuration
    private let fullRescoreInterval: TimeInterval = 86400   // 24 hours — daily re-rank
    private let startupDelaySeconds: TimeInterval = 90
    private let checkIntervalSeconds: TimeInterval = 300    // Check every 5 minutes
    private let minimumTaskCount = 2
    private let defaultVisibleAICount = 5

    /// AI task IDs that are allowed to be visible (top N by score)
    private(set) var visibleAITaskIds: Set<String> = []

    /// Whether prioritization has completed at least once
    private(set) var hasCompletedScoring = false

    private init() {
        // Restore persisted timestamps
        self.lastFullRunTime = UserDefaults.standard.object(forKey: Self.fullRunKey) as? Date

        do {
            self.geminiClient = try GeminiClient(model: "gemini-3-pro-preview")
        } catch {
            log("TaskPrioritize: Failed to initialize GeminiClient: \(error)")
            self.geminiClient = nil
        }

        if let last = self.lastFullRunTime {
            let hoursAgo = Int(Date().timeIntervalSince(last) / 3600)
            log("TaskPrioritize: Last full rescore was \(hoursAgo)h ago")
        } else {
            log("TaskPrioritize: No previous full rescore recorded")
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
                await self.checkAndRescore()
                try? await Task.sleep(nanoseconds: UInt64(300 * 1_000_000_000))
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

    private func checkAndRescore() async {
        let now = Date()
        let timeSinceFull = lastFullRunTime.map { now.timeIntervalSince($0) } ?? .infinity
        if timeSinceFull >= fullRescoreInterval {
            await runFullRescore()
        }
    }

    /// Force a full re-scoring (e.g. from settings button). Clears all existing scores first.
    func forceFullRescore() async {
        do {
            try await ActionItemStorage.shared.clearAllRelevanceScores()
        } catch {
            log("TaskPrioritize: Failed to clear scores: \(error)")
        }
        lastFullRunTime = nil
        await runFullRescore()
    }

    /// Load the allowlist from SQLite without triggering a full rescore.
    /// Called early in task loading so the filter is active before the first render.
    func ensureAllowlistLoaded() async {
        guard !hasCompletedScoring else { return }
        await loadAllowlistFromSQLite()
    }

    /// Called when user opens Tasks tab — load allowlist immediately, trigger run if needed
    func runIfNeeded() async {
        // Always load allowlist from SQLite for instant display
        if !hasCompletedScoring {
            await loadAllowlistFromSQLite()
        }

        let now = Date()
        let timeSinceFull = lastFullRunTime.map { now.timeIntervalSince($0) } ?? .infinity
        if timeSinceFull >= fullRescoreInterval {
            await runFullRescore()
        }
    }

    // MARK: - Full Rescore (Daily)

    /// Send ALL active AI tasks to Gemini, get back only the ones that need re-ranking
    private func runFullRescore() async {
        guard !isScoringInProgress else {
            log("TaskPrioritize: [FULL] Skipping — scoring already in progress")
            return
        }
        guard let client = geminiClient else {
            log("TaskPrioritize: Skipping full rescore — Gemini client not initialized")
            return
        }

        isScoringInProgress = true
        defer { isScoringInProgress = false }

        log("TaskPrioritize: [FULL] Starting daily rescore")
        await notifyStoreStarted()

        // Get ALL AI tasks
        let allTasks: [TaskActionItem]
        do {
            allTasks = try await ActionItemStorage.shared.getAllAITasks(limit: 10000)
        } catch {
            log("TaskPrioritize: [FULL] Failed to fetch tasks: \(error)")
            await notifyStoreUpdated()
            return
        }

        log("TaskPrioritize: [FULL] Found \(allTasks.count) AI tasks")

        guard allTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: [FULL] Only \(allTasks.count) tasks, skipping")
            await loadAllowlistFromSQLite()
            await notifyStoreUpdated()
            lastFullRunTime = Date()
            return
        }

        // Fetch context
        let (referenceContext, profile, goals) = await fetchContext()

        // Build the current ranking: tasks ordered by relevanceScore ASC (1 = top)
        // Tasks without scores go at the end
        let sortedTasks = allTasks.sorted { a, b in
            let scoreA = a.relevanceScore ?? Int.max
            let scoreB = b.relevanceScore ?? Int.max
            return scoreA < scoreB
        }

        // Build task list for the prompt with current positions
        let taskLines = sortedTasks.enumerated().map { (index, task) -> String in
            var parts = ["\(index + 1). [id:\(task.id)] \(task.description)"]
            if let priority = task.priority {
                parts.append("[\(priority)]")
            }
            if let due = task.dueAt {
                let formatter = ISO8601DateFormatter()
                parts.append("[due: \(formatter.string(from: due))]")
            }
            return parts.joined(separator: " ")
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
        Review the user's task list (ranked 1 = most important, \(sortedTasks.count) = least important).

        Identify tasks that are MISRANKED — tasks whose current position doesn't match their actual importance.
        Only return tasks that need to move. Do NOT return tasks that are already well-positioned.

        Consider:
        1. Alignment with the user's goals and current priorities
        2. Time urgency (due date proximity)
        3. Actionability — specific tasks rank higher than vague ones
        4. Real-world importance (financial, health, commitments to others)
        5. Most AI-extracted tasks are noise — push vague/irrelevant tasks down

        \(contextSection)CURRENT TASK RANKING (1 = most important):
        \(taskLines)

        Return ONLY the tasks that need re-ranking, with their new position numbers.
        New positions should be relative to the current list size (1 to \(sortedTasks.count)).
        """

        let systemPrompt = """
        You are a task prioritization assistant. You review a ranked task list and identify \
        tasks that are misranked. Be selective — only return tasks that genuinely need to move. \
        If the ranking looks reasonable, return an empty list. Be decisive about pushing noise \
        and vague tasks down and promoting urgent, goal-aligned tasks up.
        """

        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "reranked_tasks": .init(
                    type: "array",
                    description: "Tasks that need to be moved, with new positions",
                    items: .init(
                        type: "object",
                        properties: [
                            "task_id": .init(type: "string", description: "The task ID"),
                            "new_position": .init(type: "integer", description: "New rank position (1 = most important)")
                        ],
                        required: ["task_id", "new_position"]
                    )
                ),
                "reasoning": .init(type: "string", description: "Brief explanation of major ranking changes")
            ],
            required: ["reranked_tasks", "reasoning"]
        )

        log("TaskPrioritize: [FULL] Sending \(sortedTasks.count) tasks to Gemini")

        let responseText: String
        do {
            responseText = try await client.sendRequest(
                prompt: prompt,
                systemPrompt: systemPrompt,
                responseSchema: responseSchema
            )
        } catch {
            log("TaskPrioritize: [FULL] Gemini request failed: \(error)")
            await notifyStoreUpdated()
            return
        }

        // Log truncated response for debugging
        let truncated = responseText.prefix(500)
        log("TaskPrioritize: [FULL] Gemini response (\(responseText.count) chars): \(truncated)\(responseText.count > 500 ? "..." : "")")

        guard let data = responseText.data(using: .utf8) else {
            log("TaskPrioritize: [FULL] Failed to convert response to data")
            await notifyStoreUpdated()
            return
        }

        let result: ReRankingResponse
        do {
            result = try JSONDecoder().decode(ReRankingResponse.self, from: data)
        } catch {
            log("TaskPrioritize: [FULL] Failed to parse re-ranking response: \(error)")
            await notifyStoreUpdated()
            return
        }

        log("TaskPrioritize: [FULL] Gemini returned \(result.rerankedTasks.count) tasks to re-rank")
        if !result.reasoning.isEmpty {
            log("TaskPrioritize: [FULL] Reasoning: \(result.reasoning.prefix(300))")
        }

        // Validate: only keep task IDs that exist in our list
        let validIds = Set(allTasks.map { $0.id })
        let validReranks = result.rerankedTasks.filter { validIds.contains($0.taskId) }

        if validReranks.count != result.rerankedTasks.count {
            log("TaskPrioritize: [FULL] Filtered out \(result.rerankedTasks.count - validReranks.count) invalid task IDs")
        }

        if !validReranks.isEmpty {
            let reranks = validReranks.map { (backendId: $0.taskId, newPosition: $0.newPosition) }
            do {
                try await ActionItemStorage.shared.applySelectiveReranking(reranks)
                log("TaskPrioritize: [FULL] Applied selective re-ranking for \(validReranks.count) tasks")
            } catch {
                log("TaskPrioritize: [FULL] Failed to apply re-ranking: \(error)")
            }
        } else {
            log("TaskPrioritize: [FULL] No tasks need re-ranking, current order is good")
        }

        lastFullRunTime = Date()

        await loadAllowlistFromSQLite()
        log("TaskPrioritize: [FULL] Done. Top \(visibleAITaskIds.count) visible.")
        await notifyStoreUpdated()
    }

    // MARK: - Shared Context Fetching

    private func fetchContext() async -> (referenceContext: String, profile: String?, goals: [Goal]) {
        let userProfile = await AIUserProfileService.shared.getLatestProfile()

        let goals: [Goal]
        do {
            goals = try await APIClient.shared.getGoals()
        } catch {
            log("TaskPrioritize: Failed to fetch goals: \(error)")
            goals = []
        }

        let referenceTasks: [TaskActionItem]
        do {
            referenceTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 100,
                completed: true
            )
        } catch {
            log("TaskPrioritize: Failed to fetch reference tasks: \(error)")
            referenceTasks = []
        }
        let referenceContext = buildReferenceContext(referenceTasks)

        return (referenceContext, userProfile?.profileText, goals)
    }

    // MARK: - Allowlist from SQLite

    /// Reload the allowlist from SQLite. Call after completing/deleting a task
    /// so a new task can fill the vacated slot.
    func reloadAllowlist() async {
        await loadAllowlistFromSQLite()
    }

    private func loadAllowlistFromSQLite() async {
        do {
            // Top 5 globally — no date filter. The store will ensure these are loaded.
            let topTasks = try await ActionItemStorage.shared.getScoredAITasks(
                limit: defaultVisibleAICount
            )
            var ids = Set(topTasks.map { $0.id })

            // Ensure at least one no-deadline task is visible (so the section renders)
            if let noDeadlineTask = try await ActionItemStorage.shared.getTopScoredNoDeadlineTask(),
               !ids.contains(noDeadlineTask.id) {
                ids.insert(noDeadlineTask.id)
            }

            visibleAITaskIds = ids
            hasCompletedScoring = true
            log("TaskPrioritize: Loaded allowlist from SQLite — \(visibleAITaskIds.count) AI tasks visible")
        } catch {
            log("TaskPrioritize: Failed to load allowlist from SQLite: \(error)")
        }
    }

    // MARK: - Context Builders

    /// Build a context string from completed tasks showing what the user engages with
    private func buildReferenceContext(_ tasks: [TaskActionItem]) -> String {
        guard !tasks.isEmpty else { return "" }

        let completed = tasks.filter { !($0.description.isEmpty) }.prefix(50)
        guard !completed.isEmpty else { return "" }

        let lines = completed.map { task -> String in
            "- [completed] \(task.description)"
        }.joined(separator: "\n")

        return "TASKS THE USER HAS COMPLETED (for reference — do NOT rank these):\n\(lines)"
    }

    // MARK: - Notifications

    private func notifyStoreStarted() async {
        await MainActor.run {
            NotificationCenter.default.post(name: .taskPrioritizationDidStart, object: nil)
        }
    }

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

private struct ReRankingResponse: Codable {
    let rerankedTasks: [ReRankedTask]
    let reasoning: String

    struct ReRankedTask: Codable {
        let taskId: String
        let newPosition: Int

        enum CodingKeys: String, CodingKey {
            case taskId = "task_id"
            case newPosition = "new_position"
        }
    }

    enum CodingKeys: String, CodingKey {
        case rerankedTasks = "reranked_tasks"
        case reasoning
    }
}
