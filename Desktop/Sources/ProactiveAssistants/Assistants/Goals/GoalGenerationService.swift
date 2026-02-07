import Foundation

/// Service that automatically generates goals every 100 conversations
@MainActor
class GoalGenerationService {
    static let shared = GoalGenerationService()

    private static let kLastGenerationConversationCount = "goalGeneration_lastConversationCount"
    private let conversationInterval = 100
    private let maxActiveGoals = 3

    private init() {}

    // MARK: - Conversation Milestone Check

    /// Called after each conversation is saved. Checks if we've hit the 100-conversation milestone.
    func onConversationCreated() {
        Task {
            await checkConversationMilestone()
        }
    }

    /// Check if the user has crossed the next 100-conversation milestone
    private func checkConversationMilestone() async {
        do {
            let totalCount = try await APIClient.shared.getConversationsCount()
            let lastCount = UserDefaults.standard.integer(forKey: Self.kLastGenerationConversationCount)

            // First time: seed the count without generating
            if lastCount == 0 {
                UserDefaults.standard.set(totalCount, forKey: Self.kLastGenerationConversationCount)
                log("GoalGenerationService: Seeded conversation count at \(totalCount)")
                return
            }

            let conversationsSinceLast = totalCount - lastCount
            if conversationsSinceLast < conversationInterval {
                log("GoalGenerationService: \(conversationsSinceLast)/\(conversationInterval) conversations since last generation, waiting...")
                return
            }

            log("GoalGenerationService: Milestone reached — \(conversationsSinceLast) conversations since last generation (total: \(totalCount))")
            await generateGoalIfNeeded(totalCount: totalCount)

        } catch {
            log("GoalGenerationService: Failed to check conversation count: \(error.localizedDescription)")
        }
    }

    /// Generate a goal if the user has room for more
    private func generateGoalIfNeeded(totalCount: Int) async {
        do {
            let goals = try await APIClient.shared.getGoals()
            let activeGoals = goals.filter { $0.isActive }

            if activeGoals.count >= maxActiveGoals {
                log("GoalGenerationService: User already has \(activeGoals.count) active goals (max \(maxActiveGoals)), skipping")
                // Still update the count so we don't keep checking every conversation
                UserDefaults.standard.set(totalCount, forKey: Self.kLastGenerationConversationCount)
                return
            }

            log("GoalGenerationService: User has \(activeGoals.count)/\(maxActiveGoals) goals, generating one...")

            let goal = try await GoalsAIService.shared.generateGoal()

            UserDefaults.standard.set(totalCount, forKey: Self.kLastGenerationConversationCount)
            log("GoalGenerationService: Successfully created goal '\(goal.title)' at conversation #\(totalCount)")

            // Notify the user
            NotificationService.shared.sendNotification(
                title: "New Goal",
                message: goal.title,
                assistantId: "goals"
            )

            // Notify the UI to refresh
            NotificationCenter.default.post(name: .goalAutoCreated, object: goal)

        } catch {
            log("GoalGenerationService: Failed to generate goal: \(error.localizedDescription)")
        }
    }

    /// Manual trigger that bypasses the conversation count check
    func generateNow() async {
        log("GoalGenerationService: Manual generation triggered")
        let totalCount = (try? await APIClient.shared.getConversationsCount()) ?? 0
        await generateGoalIfNeeded(totalCount: totalCount)
    }
}
