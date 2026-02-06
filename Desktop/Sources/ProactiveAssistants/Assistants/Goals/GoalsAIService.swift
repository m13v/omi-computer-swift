import Foundation

/// Service for AI-powered goal features using direct Gemini calls
actor GoalsAIService {
    static let shared = GoalsAIService()

    private var geminiClient: GeminiClient?

    private init() {
        do {
            self.geminiClient = try GeminiClient(model: "gemini-2.0-flash")
        } catch {
            log("GoalsAIService: Failed to initialize GeminiClient: \(error)")
            self.geminiClient = nil
        }
    }

    // MARK: - Suggest Goal

    /// Generate a goal suggestion based on user's memories
    func suggestGoal() async throws -> GoalSuggestion {
        guard let client = geminiClient else {
            throw GoalsAIError.clientNotInitialized
        }

        // 1. Fetch memories via API
        let memories = try await APIClient.shared.getMemories(limit: 50)
        let memoryContext = memories.prefix(20).map { $0.content }.joined(separator: "\n")

        // Handle case with no memories
        if memoryContext.isEmpty {
            return GoalSuggestion(
                suggestedTitle: "Learn something new every day",
                suggestedType: "scale",
                suggestedTarget: 10,
                suggestedMin: 0,
                suggestedMax: 10,
                reasoning: "Start tracking your daily learning progress!"
            )
        }

        // 2. Build prompt
        let prompt = GoalPrompts.suggestGoal
            .replacingOccurrences(of: "{memory_context}", with: memoryContext)

        // 3. Build response schema
        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "suggested_title": .init(type: "string", description: "Brief, actionable goal title"),
                "suggested_type": .init(type: "string", enum: ["boolean", "scale", "numeric"], description: "Type of goal"),
                "suggested_target": .init(type: "number", description: "Target value for the goal"),
                "suggested_min": .init(type: "number", description: "Minimum value"),
                "suggested_max": .init(type: "number", description: "Maximum value"),
                "reasoning": .init(type: "string", description: "Why this goal fits the user")
            ],
            required: ["suggested_title", "suggested_type", "suggested_target", "suggested_min", "suggested_max", "reasoning"]
        )

        // 4. Call Gemini
        let responseText = try await client.sendRequest(
            prompt: prompt,
            systemPrompt: "You are a goal coach. Suggest meaningful, achievable goals based on user context.",
            responseSchema: responseSchema
        )

        // 5. Parse response
        guard let data = responseText.data(using: .utf8) else {
            throw GoalsAIError.invalidResponse
        }

        return try JSONDecoder().decode(GoalSuggestion.self, from: data)
    }

    // MARK: - Get Goal Advice

    /// Get AI-generated actionable advice for achieving a goal
    func getGoalAdvice(goal: Goal) async throws -> String {
        guard let client = geminiClient else {
            throw GoalsAIError.clientNotInitialized
        }

        // 1. Fetch context
        let memories = try await APIClient.shared.getMemories(limit: 15)
        let conversations = try await APIClient.shared.getConversations(limit: 10, statuses: [.completed])

        let memoryContext = memories
            .map { String($0.content.prefix(150)) }
            .joined(separator: "\n")

        let conversationContext = conversations
            .compactMap { $0.structured.overview.isEmpty ? nil : String($0.structured.overview.prefix(250)) }
            .joined(separator: "\n")

        let progressPct = goal.targetValue > 0
            ? (goal.currentValue / goal.targetValue) * 100
            : 0

        // 2. Build prompt
        let prompt = GoalPrompts.goalAdvice
            .replacingOccurrences(of: "{goal_title}", with: goal.title)
            .replacingOccurrences(of: "{current_value}", with: String(format: "%.0f", goal.currentValue))
            .replacingOccurrences(of: "{target_value}", with: String(format: "%.0f", goal.targetValue))
            .replacingOccurrences(of: "{progress_pct}", with: String(format: "%.1f", progressPct))
            .replacingOccurrences(of: "{conversation_context}", with: conversationContext.isEmpty ? "No recent conversations" : conversationContext)
            .replacingOccurrences(of: "{memory_context}", with: memoryContext.isEmpty ? "No facts available" : memoryContext)

        // 3. Call Gemini (text response, no schema)
        let response = try await client.sendTextRequest(
            prompt: prompt,
            systemPrompt: "You are a strategic advisor. Give specific, actionable advice based on user context. Be concise."
        )

        return response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    // MARK: - Extract Progress from All Goals

    /// Extract progress for all active goals from text (e.g., after chat or conversation)
    func extractProgressFromAllGoals(text: String) async {
        guard text.count >= 10 else { return }

        do {
            let goals = try await APIClient.shared.getGoals()
            guard !goals.isEmpty else { return }

            log("GoalsAI: Checking \(goals.count) goals for progress in text (\(text.prefix(50))...)")

            for goal in goals {
                do {
                    if let result = try await extractProgress(text: text, goal: goal, updateIfFound: true),
                       result.found, let value = result.value {
                        log("GoalsAI: Found progress for '\(goal.title)': \(value)")
                    }
                } catch {
                    // Swallow per-goal errors to continue checking other goals
                    log("GoalsAI: Error extracting progress for '\(goal.title)': \(error.localizedDescription)")
                }
            }
        } catch {
            log("GoalsAI: Failed to fetch goals for progress extraction: \(error.localizedDescription)")
        }
    }

    // MARK: - Extract Progress

    /// Extract goal progress from text and optionally update via API
    func extractProgress(text: String, goal: Goal, updateIfFound: Bool = true) async throws -> ProgressExtraction? {
        guard let client = geminiClient else {
            throw GoalsAIError.clientNotInitialized
        }

        guard text.count >= 5 else {
            return nil
        }

        // Build prompt
        let prompt = GoalPrompts.extractProgress
            .replacingOccurrences(of: "{goal_title}", with: goal.title)
            .replacingOccurrences(of: "{goal_type}", with: goal.goalType.rawValue)
            .replacingOccurrences(of: "{current_value}", with: String(format: "%.0f", goal.currentValue))
            .replacingOccurrences(of: "{target_value}", with: String(format: "%.0f", goal.targetValue))
            .replacingOccurrences(of: "{text}", with: String(text.prefix(500)))

        // Build response schema
        let responseSchema = GeminiRequest.GenerationConfig.ResponseSchema(
            type: "object",
            properties: [
                "found": .init(type: "boolean", description: "Whether progress was found"),
                "value": .init(type: "number", description: "The extracted progress value"),
                "reasoning": .init(type: "string", description: "Brief explanation")
            ],
            required: ["found"]
        )

        // Call Gemini
        let responseText = try await client.sendRequest(
            prompt: prompt,
            systemPrompt: "Extract goal progress from text. Only return found=true if confident about the specific goal.",
            responseSchema: responseSchema
        )

        guard let data = responseText.data(using: .utf8) else {
            return nil
        }

        let result = try JSONDecoder().decode(ProgressExtraction.self, from: data)

        // Update via API if found and requested
        if updateIfFound, result.found, let value = result.value, value != goal.currentValue {
            log("GoalsAI: Updating progress for '\(goal.title)': \(goal.currentValue) -> \(value)")
            _ = try await APIClient.shared.updateGoalProgress(goalId: goal.id, currentValue: value)
        }

        return result
    }
}

// MARK: - Errors

enum GoalsAIError: LocalizedError {
    case clientNotInitialized
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .clientNotInitialized:
            return "Gemini client not initialized. Check GEMINI_API_KEY."
        case .invalidResponse:
            return "Invalid response from AI service"
        }
    }
}
