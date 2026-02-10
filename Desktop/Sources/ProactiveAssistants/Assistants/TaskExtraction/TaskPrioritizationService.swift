import Foundation

/// Service that ranks AI-generated tasks by relevance to the user's profile,
/// goals, and task engagement history. Uses listwise ranking with Gemini 3 Pro
/// in overlapping batches — the model returns tasks in ranked order (not scores),
/// and overlap tasks stitch batches into a coherent global ranking.
/// Scores are persisted to SQLite. Manual tasks are always shown.
/// Two cadences: daily full re-rank of all tasks + every 2 hours re-rank 200 most recent.
actor TaskPrioritizationService {
    static let shared = TaskPrioritizationService()

    private var geminiClient: GeminiClient?
    private var timer: Task<Void, Never>?
    private var isRunning = false
    private var isScoringInProgress = false

    // Persisted to UserDefaults so they survive app restarts
    private static let fullRunKey = "TaskPrioritize.lastFullRunTime"
    private static let partialRunKey = "TaskPrioritize.lastPartialRunTime"

    private var lastFullRunTime: Date? {
        didSet { UserDefaults.standard.set(lastFullRunTime, forKey: Self.fullRunKey) }
    }
    private var lastPartialRunTime: Date? {
        didSet { UserDefaults.standard.set(lastPartialRunTime, forKey: Self.partialRunKey) }
    }

    // Configuration
    private let fullRescoreInterval: TimeInterval = 86400   // 24 hours — full re-rank of all tasks
    private let partialRescoreInterval: TimeInterval = 7200 // 2 hours — re-rank 200 most recent tasks
    private let startupDelaySeconds: TimeInterval = 90
    private let checkIntervalSeconds: TimeInterval = 300    // Check every 5 minutes
    private let minimumTaskCount = 2
    private let defaultVisibleAICount = 5
    private let partialRescoreCount = 200
    private let anchorCount = 50  // Anchor tasks for calibration in partial runs
    private let batchSize = 250
    private let batchStepSize = 200  // 50-task overlap between consecutive batches

    /// AI task IDs that are allowed to be visible (top N by score)
    private(set) var visibleAITaskIds: Set<String> = []

    /// Whether prioritization has completed at least once
    private(set) var hasCompletedScoring = false

    private init() {
        // Restore persisted timestamps
        self.lastFullRunTime = UserDefaults.standard.object(forKey: Self.fullRunKey) as? Date
        self.lastPartialRunTime = UserDefaults.standard.object(forKey: Self.partialRunKey) as? Date

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
        let timeSincePartial = lastPartialRunTime.map { now.timeIntervalSince($0) } ?? .infinity

        if timeSinceFull >= fullRescoreInterval {
            await runFullRescore()
        } else if timeSincePartial >= partialRescoreInterval {
            await runPartialRescore()
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
        lastPartialRunTime = nil
        await runFullRescore()
    }

    /// Called when user opens Tasks tab — load allowlist immediately, trigger run if needed
    func runIfNeeded() async {
        // Always load allowlist from SQLite for instant display
        if !hasCompletedScoring {
            await loadAllowlistFromSQLite()
        }

        let now = Date()
        let timeSinceFull = lastFullRunTime.map { now.timeIntervalSince($0) } ?? .infinity
        let timeSincePartial = lastPartialRunTime.map { now.timeIntervalSince($0) } ?? .infinity

        if timeSinceFull >= fullRescoreInterval {
            await runFullRescore()
        } else if timeSincePartial >= partialRescoreInterval {
            await runPartialRescore()
        }
    }

    // MARK: - Full Rescore (Daily)

    /// Clear all scores and re-rank ALL AI tasks from scratch
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

        log("TaskPrioritize: [FULL] Starting daily full rescore")
        await notifyStoreStarted()

        // Get ALL AI tasks (don't clear scores — old scores stay valid until overwritten)
        let allTasks: [TaskActionItem]
        do {
            allTasks = try await ActionItemStorage.shared.getAllAITasks(limit: 10000)
        } catch {
            log("TaskPrioritize: [FULL] Failed to fetch tasks: \(error)")
            await notifyStoreUpdated()
            return
        }

        log("TaskPrioritize: [FULL] Ranking \(allTasks.count) AI tasks")

        guard allTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: [FULL] Only \(allTasks.count) tasks, skipping")
            await loadAllowlistFromSQLite()
            await notifyStoreUpdated()
            lastFullRunTime = Date()
            lastPartialRunTime = Date()
            return
        }

        // Fetch context
        let (referenceContext, profile, goals) = await fetchContext()

        // Rank in overlapping batches
        await rankInBatches(
            tasks: allTasks,
            existingScores: [:],
            referenceContext: referenceContext,
            profile: profile,
            goals: goals,
            client: client,
            label: "FULL"
        )

        lastFullRunTime = Date()
        lastPartialRunTime = Date()  // Reset partial timer too

        await loadAllowlistFromSQLite()
        log("TaskPrioritize: [FULL] Done. \(allTasks.count) tasks ranked. Top \(visibleAITaskIds.count) visible.")
        await notifyStoreUpdated()
    }

    // MARK: - Partial Rescore (Every 2 Hours)

    /// Re-rank the 200 most recent AI tasks with anchor calibration against the global scale
    private func runPartialRescore() async {
        guard !isScoringInProgress else {
            log("TaskPrioritize: [PARTIAL] Skipping — scoring already in progress")
            return
        }
        guard let client = geminiClient else {
            log("TaskPrioritize: Skipping partial rescore — Gemini client not initialized")
            return
        }

        isScoringInProgress = true
        defer { isScoringInProgress = false }

        log("TaskPrioritize: [PARTIAL] Starting 2-hour partial rescore")
        await notifyStoreStarted()

        // Get 200 most recent AI tasks (regardless of score status)
        let recentTasks: [TaskActionItem]
        do {
            recentTasks = try await ActionItemStorage.shared.getRecentAITasks(limit: partialRescoreCount)
        } catch {
            log("TaskPrioritize: [PARTIAL] Failed to fetch recent tasks: \(error)")
            await notifyStoreUpdated()
            return
        }

        guard recentTasks.count >= minimumTaskCount else {
            log("TaskPrioritize: [PARTIAL] Only \(recentTasks.count) recent tasks, skipping")
            lastPartialRunTime = Date()
            await notifyStoreUpdated()
            return
        }

        let recentIds = Set(recentTasks.map { $0.id })

        // Get scored anchor tasks that are NOT in the recent set (for calibration)
        let anchors: [TaskActionItem]
        do {
            let allScored = try await ActionItemStorage.shared.getScoredAITasks(limit: 10000)
            anchors = selectDiverseAnchors(
                from: allScored.filter { !recentIds.contains($0.id) },
                count: anchorCount
            )
        } catch {
            log("TaskPrioritize: [PARTIAL] Failed to fetch anchors: \(error)")
            anchors = []
        }

        log("TaskPrioritize: [PARTIAL] Ranking \(recentTasks.count) recent tasks with \(anchors.count) anchors")

        // Build combined batch (recent tasks + anchors for calibration)
        let combinedBatch = recentTasks + anchors

        // Build existing scores from anchors
        var anchorScores: [String: Int] = [:]
        for anchor in anchors {
            if let score = anchor.relevanceScore {
                anchorScores[anchor.id] = score
            }
        }

        // Fetch context
        let (referenceContext, profile, goals) = await fetchContext()

        // Rank the combined batch (single batch since 200 + 50 = 250 fits in one call)
        let rankedIds = await rankBatchWithGemini(
            batch: combinedBatch,
            referenceContext: referenceContext,
            profile: profile,
            goals: goals,
            client: client
        )

        guard let rankedIds = rankedIds, !rankedIds.isEmpty else {
            log("TaskPrioritize: [PARTIAL] Ranking failed")
            lastPartialRunTime = Date()
            await notifyStoreUpdated()
            return
        }

        // Stitch scores using anchors for calibration
        let batchScores: [String: Int]
        if anchorScores.isEmpty {
            batchScores = assignLinearScores(rankedIds: rankedIds)
            log("TaskPrioritize: [PARTIAL] Linear scoring (no anchors)")
        } else {
            batchScores = stitchScores(rankedIds: rankedIds, globalScores: anchorScores)
            log("TaskPrioritize: [PARTIAL] Stitched with \(anchors.count) anchors")
        }

        // Only persist scores for the target tasks (not anchors — their scores stay stable)
        let targetScores = batchScores.filter { recentIds.contains($0.key) }
        do {
            try await ActionItemStorage.shared.updateRelevanceScores(targetScores)
            log("TaskPrioritize: [PARTIAL] Persisted \(targetScores.count) scores")
        } catch {
            log("TaskPrioritize: [PARTIAL] Failed to persist scores: \(error)")
        }

        lastPartialRunTime = Date()

        await loadAllowlistFromSQLite()
        log("TaskPrioritize: [PARTIAL] Done. Top \(visibleAITaskIds.count) visible.")
        await notifyStoreUpdated()
    }

    /// Select anchor tasks spread across the score range for calibration
    private func selectDiverseAnchors(from tasks: [TaskActionItem], count: Int) -> [TaskActionItem] {
        guard tasks.count > count else { return tasks }

        // Tasks are already sorted by score DESC from getScoredAITasks
        // Sample evenly across the range
        var anchors: [TaskActionItem] = []
        let step = Double(tasks.count - 1) / Double(count - 1)

        for i in 0..<count {
            let index = min(Int(round(Double(i) * step)), tasks.count - 1)
            anchors.append(tasks[index])
        }

        return anchors
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

    private func loadAllowlistFromSQLite() async {
        do {
            // Top 5 globally — no date filter. The store will ensure these are loaded.
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

    /// Rank tasks in overlapping batches. Each batch asks the model to return
    /// task IDs in ranked order (most → least relevant). Overlap tasks between batches
    /// are used to stitch rankings into a coherent global score.
    private func rankInBatches(
        tasks: [TaskActionItem],
        existingScores: [String: Int],
        referenceContext: String,
        profile: String?,
        goals: [Goal],
        client: GeminiClient,
        label: String
    ) async {
        // Build overlapping batches
        var batches: [[TaskActionItem]] = []
        var startIndex = 0

        while startIndex < tasks.count {
            let endIndex = min(startIndex + batchSize, tasks.count)
            let batch = Array(tasks[startIndex..<endIndex])
            batches.append(batch)
            startIndex += batchStepSize
            if endIndex == tasks.count { break }
        }

        log("TaskPrioritize: [\(label)] \(tasks.count) tasks in \(batches.count) batches")

        // Track scores assigned so far (for overlap stitching)
        var globalScores = existingScores

        for (i, batch) in batches.enumerated() {
            log("TaskPrioritize: [\(label)] Ranking batch \(i + 1)/\(batches.count) (\(batch.count) tasks)")

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
                log("TaskPrioritize: [\(label)] Batch \(i + 1) failed, skipping")
                continue
            }

            // Convert ranking to scores
            let batchScores: [String: Int]

            if overlapTasks.isEmpty {
                batchScores = assignLinearScores(rankedIds: rankedIds)
                log("TaskPrioritize: [\(label)] Batch \(i + 1) — linear scoring (\(rankedIds.count) ranked)")
            } else {
                batchScores = stitchScores(rankedIds: rankedIds, globalScores: globalScores)
                log("TaskPrioritize: [\(label)] Batch \(i + 1) — stitched with \(overlapTasks.count) overlap anchors (\(rankedIds.count) ranked)")
            }

            // Update global scores
            for (id, score) in batchScores {
                globalScores[id] = score
            }

            // Persist to SQLite after each batch
            do {
                try await ActionItemStorage.shared.updateRelevanceScores(batchScores)
                log("TaskPrioritize: [\(label)] Batch \(i + 1) persisted \(batchScores.count) scores")
            } catch {
                log("TaskPrioritize: [\(label)] Failed to persist batch \(i + 1) scores: \(error)")
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
            let score: Int

            if position <= anchors.first!.position {
                // Before first anchor: extrapolate upward
                if anchors.count >= 2 {
                    let a = anchors[0], b = anchors[1]
                    let slope = Double(a.score - b.score) / Double(b.position - a.position)
                    score = min(100, Int(round(Double(a.score) + slope * Double(a.position - position))))
                } else {
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
                    items: .init(type: "string", properties: nil, required: nil)
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
