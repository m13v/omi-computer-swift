import Foundation

/// Executes tool calls from Gemini and returns results
/// Tools call backend APIs to perform actions or fetch data
@MainActor
class ChatToolExecutor {

    /// Execute a tool call and return the result as a string
    static func execute(_ toolCall: ToolCall) async -> String {
        log("Executing tool: \(toolCall.name) with args: \(toolCall.arguments)")

        switch toolCall.name {
        case "create_action_item":
            return await executeCreateActionItem(toolCall.arguments)

        case "get_conversations":
            return await executeGetConversations(toolCall.arguments)

        case "get_memories":
            return await executeGetMemories(toolCall.arguments)

        default:
            return "Unknown tool: \(toolCall.name)"
        }
    }

    /// Execute multiple tool calls and return results keyed by tool name
    static func executeAll(_ toolCalls: [ToolCall]) async -> [String: String] {
        var results: [String: String] = [:]

        for call in toolCalls {
            results[call.name] = await execute(call)
        }

        return results
    }

    // MARK: - Tool Implementations

    /// Create an action item / task
    private static func executeCreateActionItem(_ args: [String: Any]) async -> String {
        guard let description = args["description"] as? String else {
            return "Error: description is required"
        }

        let priority = args["priority"] as? String
        let dueDateString = args["due_date"] as? String

        // Parse due date if provided
        var dueDate: Date? = nil
        if let dateStr = dueDateString {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            dueDate = formatter.date(from: dateStr)

            // Try without fractional seconds
            if dueDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                dueDate = formatter.date(from: dateStr)
            }
        }

        do {
            let actionItem = try await APIClient.shared.createActionItem(
                description: description,
                dueAt: dueDate,
                source: "chat",
                priority: priority
            )

            var result = "Created task: \"\(actionItem.description)\""
            if let due = actionItem.dueAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                result += " (due: \(formatter.string(from: due)))"
            }

            log("Tool create_action_item succeeded: \(actionItem.id)")
            return result

        } catch {
            logError("Tool create_action_item failed", error: error)
            return "Failed to create task: \(error.localizedDescription)"
        }
    }

    /// Get recent conversations
    private static func executeGetConversations(_ args: [String: Any]) async -> String {
        let limit = (args["limit"] as? Int) ?? 10
        let days = (args["days"] as? Int) ?? 7

        // Calculate start date
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        do {
            let conversations = try await APIClient.shared.getConversations(
                limit: limit,
                offset: 0,
                statuses: [],
                includeDiscarded: false,
                startDate: startDate
            )

            if conversations.isEmpty {
                return "No conversations found in the last \(days) days."
            }

            // Format conversations for the model
            var lines: [String] = ["Found \(conversations.count) conversation(s):"]

            for (index, conv) in conversations.prefix(limit).enumerated() {
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                dateFormatter.timeStyle = .short
                let dateStr = dateFormatter.string(from: conv.createdAt)

                lines.append("\(index + 1). \(conv.structured.emoji) \(conv.title) (\(dateStr))")
                if !conv.overview.isEmpty {
                    lines.append("   Summary: \(conv.overview)")
                }
            }

            log("Tool get_conversations returned \(conversations.count) results")
            return lines.joined(separator: "\n")

        } catch {
            logError("Tool get_conversations failed", error: error)
            return "Failed to fetch conversations: \(error.localizedDescription)"
        }
    }

    /// Get user memories/facts
    private static func executeGetMemories(_ args: [String: Any]) async -> String {
        let limit = (args["limit"] as? Int) ?? 20

        do {
            let memories = try await APIClient.shared.getMemories(limit: limit)

            if memories.isEmpty {
                return "No memories found."
            }

            // Format memories for the model
            var lines: [String] = ["Found \(memories.count) fact(s) about the user:"]

            for memory in memories.prefix(limit) {
                lines.append("- \(memory.content)")
            }

            log("Tool get_memories returned \(memories.count) results")
            return lines.joined(separator: "\n")

        } catch {
            logError("Tool get_memories failed", error: error)
            return "Failed to fetch memories: \(error.localizedDescription)"
        }
    }
}
