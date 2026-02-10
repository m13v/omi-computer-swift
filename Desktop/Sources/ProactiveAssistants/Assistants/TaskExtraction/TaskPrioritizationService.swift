import Foundation

/// Service that ranks AI-generated tasks by relevance to the user's profile,
/// goals, and task engagement history. Uses listwise ranking with Gemini 3 Pro
/// in overlapping batches — the model returns tasks in ranked order (not scores),
/// and overlap tasks stitch batches into a coherent global ranking.
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

    /// Force a full re-scoring (e.g. from settings button). Clears all existing scores first.
    func forceFullRescore() async {
        do {
            try await ActionItemStorage.shared.clearAllRelevanceScores()
        } catch {
            log("TaskPrioritize: Failed to clear scores: \(error)")
        }
        lastRunTime = nil
        await runPrioritization()
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

        // 1. Load already-scored and unscored AI tasks from SQLite
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

        // 3. Build reference context (completed tasks the user engaged with)
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

        // 4. Rank unscored tasks in overlapping batches with overlap stitching
        await rankInBatches(
            unscoredTasks: unscoredTasks,
            scoredTasks: scoredTasks,
            referenceContext: referenceContext,
            profile: userProfile?.profileText,
            goals: goals,
            client: client
        )

        // 5. Reload allowlist from SQLite
        await loadAllowlistFromSQLite()

        let totalAI = scoredTasks.count + unscoredTasks.count
        log("TaskPrioritize: Done. \(totalAI) total AI tasks. Top \(visibleAITaskIds.count) visible.")
        await notifyStoreUpdated()
    }

    // MARK: - Allowlist from SQLite

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

    // MARK: - Listwise Ranking in Batches

    /// Rank unscored tasks in overlapping batches. Each batch asks the model to return
    /// task IDs in ranked order (most → least relevant). Overlap tasks between batches
    /// are used to stitch rankings into a coherent global score.
    private func rankInBatches(
        unscoredTasks: [TaskActionItem],
        scoredTasks: [TaskActionItem],
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async {
        // Build overlapping batches of unscored tasks
        var batches: [[TaskActionItem]] = []
        var startIndex = 0

        while startIndex < unscoredTasks.count {
            let endIndex = min(startIndex + batchSize, unscoredTasks.count)
            let batch = Array(unscoredTasks[startIndex..<endIndex])
            batches.append(batch)
            startIndex += batchStepSize
            if endIndex == unscoredTasks.count { break }
        }

        log("TaskPrioritize: Ranking \(unscoredTasks.count) unscored tasks in \(batches.count) batches")

        // Track scores assigned so far (for overlap stitching)
        var globalScores: [String: Int] = [:]

        // Seed with existing scored tasks
        for task in scoredTasks {
            if let score = task.relevanceScore {
                globalScores[task.id] = score
            }
        }

        for (i, batch) in batches.enumerated() {
            log("TaskPrioritize: Ranking batch \(i + 1)/\(batches.count) (\(batch.count) tasks)")

            // Find overlap tasks in this batch that already have global scores
            let overlapTasks = batch.filter { globalScores[$0.id] != nil }

            let rankedIds = await rankBatchWithGemini(
                batch: batch,
                referenceContext: referenceContext,
                profile: profile,
                goals: goals,
                client: client
            )

            guard let rankedIds = rankedIds, !rankedIds.isEmpty else {
                log("TaskPrioritize: Batch \(i + 1) failed, skipping")
                continue
            }

            // Convert ranking to scores
            let batchScores: [String: Int]

            if overlapTasks.isEmpty {
                // First batch or no overlap: assign linear scores from position
                batchScores = assignLinearScores(rankedIds: rankedIds)
                log("TaskPrioritize: Batch \(i + 1) — linear scoring (\(rankedIds.count) ranked)")
            } else {
                // Stitch using overlap tasks as calibration anchors
                batchScores = stitchScores(
                    rankedIds: rankedIds,
                    globalScores: globalScores
                )
                log("TaskPrioritize: Batch \(i + 1) — stitched with \(overlapTasks.count) overlap anchors (\(rankedIds.count) ranked)")
            }

            // Update global scores
            for (id, score) in batchScores {
                globalScores[id] = score
            }

            // Persist to SQLite after each batch
            do {
                try await ActionItemStorage.shared.updateRelevanceScores(batchScores)
                log("TaskPrioritize: Batch \(i + 1) persisted \(batchScores.count) scores")
            } catch {
                log("TaskPrioritize: Failed to persist batch \(i + 1) scores: \(error)")
            }

            // Update UI progressively
            await loadAllowlistFromSQLite()
            await notifyStoreUpdated()
        }
    }

    // MARK: - Score Assignment

    /// Assign linear scores based on position in the ranked list.
    /// Position 0 (most relevant) → 100, last position → 0.
    private func assignLinearScores(rankedIds: [String]) -> [String: Int] {
        guard rankedIds.count > 1 else {
            if let id = rankedIds.first { return [id: 50] }
            return [:]
        }

        var scores: [String: Int] = [:]
        let count = Double(rankedIds.count - 1)

        for (position, id) in rankedIds.enumerated() {
            let score = Int(round(100.0 * (1.0 - Double(position) / count)))
            scores[id] = score
        }

        return scores
    }

    /// Stitch batch ranking into global scores using overlap tasks as anchors.
    /// Overlap tasks have known global scores — their positions in this batch's ranking
    /// define a mapping from local position → global score via linear interpolation.
    private func stitchScores(
        rankedIds: [String],
        globalScores: [String: Int]
    ) -> [String: Int] {
        // Find anchor points: (position in rankedIds, known global score)
        var anchors: [(position: Int, score: Int)] = []
        for (position, id) in rankedIds.enumerated() {
            if let knownScore = globalScores[id] {
                anchors.append((position: position, score: knownScore))
            }
        }

        // If no anchors found, fall back to linear
        guard !anchors.isEmpty else {
            return assignLinearScores(rankedIds: rankedIds)
        }

        // Sort anchors by position
        anchors.sort { $0.position < $1.position }

        // For each task, interpolate between the nearest anchors
        var scores: [String: Int] = [:]
        let lastPosition = rankedIds.count - 1

        for (position, id) in rankedIds.enumerated() {
            // If this task already has a known score, use interpolated score
            // to keep the stitching consistent
            let score: Int

            if position <= anchors.first!.position {
                // Before first anchor: extrapolate upward
                if anchors.count >= 2 {
                    let a = anchors[0], b = anchors[1]
                    let slope = Double(a.score - b.score) / Double(b.position - a.position)
                    score = min(100, Int(round(Double(a.score) + slope * Double(a.position - position))))
                } else {
                    // Single anchor — scale linearly from 100 at position 0
                    let anchor = anchors[0]
                    if anchor.position == 0 {
                        score = anchor.score
                    } else {
                        let fraction = Double(position) / Double(anchor.position)
                        score = min(100, Int(round(Double(anchor.score) + (100.0 - Double(anchor.score)) * (1.0 - fraction))))
                    }
                }
            } else if position >= anchors.last!.position {
                // After last anchor: extrapolate downward
                if anchors.count >= 2 {
                    let a = anchors[anchors.count - 2], b = anchors[anchors.count - 1]
                    let slope = Double(a.score - b.score) / Double(b.position - a.position)
                    score = max(0, Int(round(Double(b.score) - slope * Double(position - b.position))))
                } else {
                    // Single anchor — scale linearly to 0 at last position
                    let anchor = anchors[0]
                    if position == lastPosition && anchor.position == lastPosition {
                        score = anchor.score
                    } else {
                        let remaining = lastPosition - anchor.position
                        let fraction = remaining > 0 ? Double(position - anchor.position) / Double(remaining) : 0
                        score = max(0, Int(round(Double(anchor.score) * (1.0 - fraction))))
                    }
                }
            } else {
                // Between two anchors: linear interpolation
                var lower = anchors[0]
                var upper = anchors[anchors.count - 1]

                for j in 0..<(anchors.count - 1) {
                    if anchors[j].position <= position && anchors[j + 1].position >= position {
                        lower = anchors[j]
                        upper = anchors[j + 1]
                        break
                    }
                }

                let range = upper.position - lower.position
                let fraction = range > 0 ? Double(position - lower.position) / Double(range) : 0
                score = Int(round(Double(lower.score) + fraction * Double(upper.score - lower.score)))
            }

            scores[id] = max(0, min(100, score))
        }

        return scores
    }

    // MARK: - Single Batch Ranking via Gemini

    /// Ask Gemini to rank tasks by relevance. Returns an ordered array of task IDs
    /// from most relevant to least relevant.
    private func rankBatchWithGemini(
        batch: [TaskActionItem],
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient
    ) async -> [String]? {

        // Build task descriptions
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
        Rank these tasks from MOST relevant to LEAST relevant for this user.

        Consider:
        1. Alignment with the user's goals and current priorities
        2. Time urgency (due date proximity)
        3. Whether the task is actionable and specific vs. vague
        4. Real-world importance (financial, health, commitments to others)
        5. Similarity to tasks the user has completed (see reference)

        Most AI-extracted tasks are noise — rank clearly actionable, goal-aligned tasks \
        at the top, and vague or irrelevant tasks at the bottom.

        \(contextSection)TASKS TO RANK:
        \(taskDescriptions)

        Return ALL task IDs in order from most relevant (first) to least relevant (last). \
        Every task ID must appear exactly once.
        """

        let systemPrompt = """
        You are a task prioritization assistant. You rank tasks by relevance to the user. \
        Be decisive — put clearly important tasks first and noise last. Every task must \
        appear in your ranking exactly once. Return only the ordered list of task IDs.
        """

        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "ranked_task_ids": .init(
                    type: "array",
                    description: "Task IDs ordered from most relevant to least relevant",
                    items: .init(type: "string")
                )
            ],
            required: ["ranked_task_ids"]
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

        let result: RankingResponse
        do {
            result = try JSONDecoder().decode(RankingResponse.self, from: data)
        } catch {
            log("TaskPrioritize: Failed to parse ranking response: \(error)")
            return nil
        }

        // Validate: only keep IDs that are in this batch
        let validIds = Set(batch.map { $0.id })
        let validRanked = result.rankedTaskIds.filter { validIds.contains($0) }

        // Add any missing IDs at the end (in case model missed some)
        let returnedIds = Set(validRanked)
        let missing = batch.map { $0.id }.filter { !returnedIds.contains($0) }
        if !missing.isEmpty {
            log("TaskPrioritize: \(missing.count) tasks missing from ranking, appending at end")
        }

        return validRanked + missing
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

private struct RankingResponse: Codable {
    let rankedTaskIds: [String]

    enum CodingKeys: String, CodingKey {
        case rankedTaskIds = "ranked_task_ids"
    }
}
