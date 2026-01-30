import SwiftUI

/// A single chat message
struct ChatMessage: Identifiable {
    let id: String
    var text: String
    let createdAt: Date
    let sender: ChatSender
    var isStreaming: Bool

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), sender: ChatSender, isStreaming: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sender = sender
        self.isStreaming = isStreaming
    }
}

enum ChatSender {
    case user
    case ai
}

/// State management for chat functionality with client-side Gemini
@MainActor
class ChatProvider: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var selectedAppId: String?

    private var geminiClient: GeminiClient?

    // MARK: - System Prompt Template (matching OMI backend)

    /// Template variables:
    /// - {user_name} - User's display name
    /// - {tz} - User's timezone
    /// - {current_datetime_str} - Current datetime string
    /// - {memories_str} - User's memories/facts (empty for now)
    private let systemPromptTemplate = """
    <assistant_role>
    You are Omi, an AI assistant & mentor for {user_name}. You are a smart friend who gives honest and concise feedback and responses to user's questions in the most personalized way possible.
    </assistant_role>

    <user_context>
    Current date/time in {user_name}'s timezone ({tz}): {current_datetime_str}
    {memories_section}
    </user_context>

    <mentor_behavior>
    You're a mentor, not a yes-man. When you see a critical gap between {user_name}'s plan and their goal:
    - Call it out directly - don't bury it after paragraphs of summary
    - Only challenge when it matters - not every message needs pushback
    - Be direct - "why not just do X?" rather than "Have you considered the alternative approach of X?"
    - Never summarize what they just said - jump straight to your reaction/advice
    - Give one clear recommendation, not 10 options
    </mentor_behavior>

    <response_style>
    Write like a real human texting - not an AI writing an essay.

    Length:
    - Default: 2-8 lines, conversational
    - Reflections/planning: can be longer but NO SUMMARIES of what they said
    - Quick replies: 1-3 lines
    - "I don't know" responses: 1-2 lines MAX

    Format:
    - NO essays summarizing their message
    - NO headers like "What you did:", "How you felt:", "Next steps:"
    - NO "Great reflection!" or corporate praise
    - Just talk normally like you're texting a friend who you respect
    - Feel free to use lowercase, casual language when appropriate
    </response_style>

    <critical_accuracy_rules>
    NEVER MAKE UP INFORMATION - THIS IS CRITICAL:
    1. If you don't have information about something, give a SHORT 1-2 line response saying you don't know.
    2. Do NOT generate plausible-sounding details even if they seem helpful.
    3. Sound like a human: "I don't have that" not "no data available"
    4. If you don't know something, say "I don't know" in 1-2 lines max.
    </critical_accuracy_rules>

    <instructions>
    - Be casual, concise, and direct—text like a friend.
    - Give specific feedback/advice; never generic.
    - Keep it short—use fewer words, bullet points when possible.
    - Always answer the question directly; no extra info, no fluff.
    - Use what you know about {user_name} to personalize your responses.
    - Show times/dates in {user_name}'s timezone ({tz}), in a natural, friendly way.
    - If you don't know, say so honestly in 1-2 lines.
    </instructions>
    """

    init() {
        do {
            self.geminiClient = try GeminiClient()
            log("ChatProvider initialized with Gemini client")
        } catch {
            logError("Failed to initialize Gemini client", error: error)
            self.errorMessage = "AI not available: \(error.localizedDescription)"
        }
    }

    // MARK: - Build System Prompt with Variables

    /// Builds the system prompt with dynamic template variables
    private func buildSystemPrompt() -> String {
        // Get user name from AuthService
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName

        // Get timezone
        let timezone = TimeZone.current.identifier

        // Format current datetime
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone.current
        let currentDatetime = dateFormatter.string(from: Date())

        // Build memories section (empty for now - can be populated later)
        let memoriesSection = ""  // TODO: Fetch user memories from backend

        // Replace template variables
        var prompt = systemPromptTemplate
        prompt = prompt.replacingOccurrences(of: "{user_name}", with: userName)
        prompt = prompt.replacingOccurrences(of: "{tz}", with: timezone)
        prompt = prompt.replacingOccurrences(of: "{current_datetime_str}", with: currentDatetime)
        prompt = prompt.replacingOccurrences(of: "{memories_section}", with: memoriesSection)

        return prompt
    }

    // MARK: - Fetch Messages

    /// Fetch chat messages (currently just clears for fresh start)
    func fetchMessages() async {
        // For client-side chat, we start fresh each session
        // In the future, we could persist locally or sync with backend
        messages.removeAll()
        errorMessage = nil
    }

    // MARK: - Send Message

    /// Send a message and get streaming AI response
    func sendMessage(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        guard let client = geminiClient else {
            errorMessage = "AI not available"
            return
        }

        isSending = true
        errorMessage = nil

        // Add user message
        let userMessage = ChatMessage(
            text: trimmedText,
            sender: .user
        )
        messages.append(userMessage)

        // Create placeholder AI message for streaming
        let aiMessageId = UUID().uuidString
        let aiMessage = ChatMessage(
            id: aiMessageId,
            text: "",
            sender: .ai,
            isStreaming: true
        )
        messages.append(aiMessage)

        do {
            // Build chat history for Gemini
            let chatHistory = buildChatHistory()

            // Build system prompt with user-specific variables
            let systemPrompt = buildSystemPrompt()

            // Stream response from Gemini
            let _ = try await client.sendChatStreamRequest(
                messages: chatHistory,
                systemPrompt: systemPrompt,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendToMessage(id: aiMessageId, text: chunk)
                    }
                }
            )

            // Mark streaming complete
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                messages[index].isStreaming = false
            }

            log("Chat response complete")
        } catch {
            // Remove AI message placeholder on error
            messages.removeAll { $0.id == aiMessageId }

            logError("Failed to get AI response", error: error)
            errorMessage = "Failed to get response: \(error.localizedDescription)"
        }

        isSending = false
    }

    /// Append text to a streaming message
    private func appendToMessage(id: String, text: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
        }
    }

    /// Build chat history in Gemini format
    private func buildChatHistory() -> [GeminiClient.ChatMessage] {
        return messages.compactMap { message in
            // Skip empty AI messages (streaming placeholder)
            if message.sender == .ai && message.text.isEmpty {
                return nil
            }
            return GeminiClient.ChatMessage(
                role: message.sender == .user ? "user" : "model",
                text: message.text
            )
        }
    }

    // MARK: - Clear Chat

    /// Clear all messages
    func clearChat() async {
        messages.removeAll()
        errorMessage = nil
        log("Chat cleared")
    }

    // MARK: - App Selection

    /// Select a chat app (for future app-specific chat)
    func selectApp(_ appId: String?) {
        guard selectedAppId != appId else { return }
        selectedAppId = appId
        messages.removeAll()
        errorMessage = nil
    }
}
