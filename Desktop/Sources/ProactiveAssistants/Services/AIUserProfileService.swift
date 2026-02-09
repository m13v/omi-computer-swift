import Foundation

/// Service that generates and maintains an AI-generated user profile.
/// Inspired by the ContextAgent paper (arXiv:2505.14668).
/// Runs once daily, fetches data from multiple sources, and calls Gemini to synthesize a concise profile.
actor AIUserProfileService {
    static let shared = AIUserProfileService()

    private let model = "gemini-3-pro-preview"
    private let maxProfileLength = 2000

    // UserDefaults keys for local storage
    private static let kProfileText = "aiUserProfileText"
    private static let kProfileGeneratedAt = "aiUserProfileGeneratedAt"
    private static let kProfileDataSourcesUsed = "aiUserProfileDataSourcesUsed"

    /// Whether profile generation is currently in progress
    private var isGenerating = false

    // MARK: - Public Interface

    /// Check if we should generate a new profile (>24h since last generation)
    nonisolated func shouldGenerate() -> Bool {
        let lastGenerated = UserDefaults.standard.double(forKey: Self.kProfileGeneratedAt)
        guard lastGenerated > 0 else { return true } // Never generated
        let elapsed = Date().timeIntervalSince1970 - lastGenerated
        return elapsed > 86400 // 24 hours
    }

    /// Get the locally stored profile text
    nonisolated func getStoredProfileText() -> String? {
        UserDefaults.standard.string(forKey: Self.kProfileText)
    }

    /// Get the locally stored generation date
    nonisolated func getStoredGeneratedAt() -> Date? {
        let ts = UserDefaults.standard.double(forKey: Self.kProfileGeneratedAt)
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    /// Get the stored data sources count
    nonisolated func getStoredDataSourcesUsed() -> Int {
        UserDefaults.standard.integer(forKey: Self.kProfileDataSourcesUsed)
    }

    /// Generate a new AI user profile from all available data sources
    func generateProfile() async throws -> (text: String, generatedAt: Date, dataSourcesUsed: Int) {
        guard !isGenerating else {
            throw ProfileError.alreadyGenerating
        }
        isGenerating = true
        defer { isGenerating = false }

        log("AIUserProfileService: Starting profile generation")

        // 1. Fetch all data sources in parallel
        let (memories, tasks, goals, conversations, messages) = await fetchDataSources()

        // 2. Count total data items
        let dataSourcesUsed = memories.count + tasks.count + goals.count + conversations.count + messages.count
        log("AIUserProfileService: Fetched \(dataSourcesUsed) data items (memories=\(memories.count), tasks=\(tasks.count), goals=\(goals.count), convos=\(conversations.count), messages=\(messages.count))")

        guard dataSourcesUsed > 0 else {
            throw ProfileError.insufficientData
        }

        // 3. Build prompt
        let prompt = buildPrompt(memories: memories, tasks: tasks, goals: goals, conversations: conversations, messages: messages)

        // 4. Call Gemini
        let gemini = try GeminiClient(model: model)
        let systemPrompt = """
        You are an AI that creates concise user profiles from behavioral data. \
        Generate a profile that captures who this person is — their priorities, patterns, \
        communication style, interests, and current focus areas. \
        Write in third person. Be specific and concrete, not generic. \
        The output MUST be under 2000 characters. \
        Do NOT use markdown headers or bullet points — write in flowing prose paragraphs.
        """

        let profileText = try await gemini.sendTextRequest(prompt: prompt, systemPrompt: systemPrompt)

        // 5. Truncate if needed
        let truncated = String(profileText.prefix(maxProfileLength))
        let generatedAt = Date()

        // 6. Save locally
        saveLocally(text: truncated, generatedAt: generatedAt, dataSourcesUsed: dataSourcesUsed)

        // 7. Sync to backend (fire-and-forget)
        Task {
            do {
                try await APIClient.shared.syncAIUserProfile(
                    profileText: truncated,
                    generatedAt: generatedAt,
                    dataSourcesUsed: dataSourcesUsed
                )
                log("AIUserProfileService: Synced profile to backend")
            } catch {
                log("AIUserProfileService: Failed to sync profile to backend: \(error.localizedDescription)")
            }
        }

        log("AIUserProfileService: Profile generated successfully (\(truncated.count) chars, \(dataSourcesUsed) data items)")
        return (text: truncated, generatedAt: generatedAt, dataSourcesUsed: dataSourcesUsed)
    }

    // MARK: - Data Fetching

    private func fetchDataSources() async -> (
        memories: [String],
        tasks: [String],
        goals: [String],
        conversations: [String],
        messages: [String]
    ) {
        async let memoriesTask = fetchMemories()
        async let tasksTask = fetchTasks()
        async let goalsTask = fetchGoals()
        async let conversationsTask = fetchConversations()
        async let messagesTask = fetchMessages()

        let memories = await memoriesTask
        let tasks = await tasksTask
        let goals = await goalsTask
        let conversations = await conversationsTask
        let messages = await messagesTask

        return (memories, tasks, goals, conversations, messages)
    }

    private func fetchMemories() async -> [String] {
        do {
            let memories = try await APIClient.shared.getMemories(limit: 100)
            return memories.map { "[\($0.category.rawValue)] \($0.content)" }
        } catch {
            log("AIUserProfileService: Failed to fetch memories: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchTasks() async -> [String] {
        do {
            let response = try await APIClient.shared.getActionItems(limit: 50)
            return response.items.map { item in
                let status = item.completed ? "done" : "todo"
                let priority = item.priority ?? "medium"
                return "[\(status)/\(priority)] \(item.description)"
            }
        } catch {
            log("AIUserProfileService: Failed to fetch tasks: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchGoals() async -> [String] {
        do {
            let goals = try await APIClient.shared.getGoals()
            return goals.filter { $0.isActive }.map { goal in
                let progress = goal.targetValue > 0 ? Int((goal.currentValue / goal.targetValue) * 100) : 0
                return "\(goal.title) (\(progress)% complete)"
            }
        } catch {
            log("AIUserProfileService: Failed to fetch goals: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchConversations() async -> [String] {
        do {
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            let conversations = try await APIClient.shared.getConversations(
                limit: 20,
                startDate: sevenDaysAgo
            )
            return conversations.compactMap { convo in
                let title = convo.structured.title
                let summary = convo.structured.overview
                guard !title.isEmpty else { return nil }
                return "\(title): \(summary)"
            }
        } catch {
            log("AIUserProfileService: Failed to fetch conversations: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchMessages() async -> [String] {
        do {
            let messages = try await APIClient.shared.getMessages(limit: 30)
            return messages.map { "[\($0.sender)] \($0.text)" }
        } catch {
            log("AIUserProfileService: Failed to fetch messages: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(
        memories: [String],
        tasks: [String],
        goals: [String],
        conversations: [String],
        messages: [String]
    ) -> String {
        var sections: [String] = []

        if !memories.isEmpty {
            sections.append("## Memories about the user\n\(memories.joined(separator: "\n"))")
        }

        if !tasks.isEmpty {
            sections.append("## Recent tasks\n\(tasks.joined(separator: "\n"))")
        }

        if !goals.isEmpty {
            sections.append("## Active goals\n\(goals.joined(separator: "\n"))")
        }

        if !conversations.isEmpty {
            sections.append("## Recent conversations (past 7 days)\n\(conversations.joined(separator: "\n"))")
        }

        if !messages.isEmpty {
            sections.append("## Recent AI chat messages\n\(messages.joined(separator: "\n"))")
        }

        return """
        Based on the following data about a user, generate a concise user profile (under 2000 characters). \
        Cover: behavioral patterns, communication style, current priorities, active goals with progress, \
        recurring themes, key interests, and recent work focus.

        \(sections.joined(separator: "\n\n"))
        """
    }

    // MARK: - Local Storage

    private nonisolated func saveLocally(text: String, generatedAt: Date, dataSourcesUsed: Int) {
        UserDefaults.standard.set(text, forKey: Self.kProfileText)
        UserDefaults.standard.set(generatedAt.timeIntervalSince1970, forKey: Self.kProfileGeneratedAt)
        UserDefaults.standard.set(dataSourcesUsed, forKey: Self.kProfileDataSourcesUsed)
    }

    // MARK: - Errors

    enum ProfileError: LocalizedError {
        case alreadyGenerating
        case insufficientData

        var errorDescription: String? {
            switch self {
            case .alreadyGenerating:
                return "Profile generation is already in progress"
            case .insufficientData:
                return "Not enough data to generate a profile"
            }
        }
    }
}
