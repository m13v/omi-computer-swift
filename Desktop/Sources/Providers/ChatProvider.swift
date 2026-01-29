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

    private let systemPrompt = """
    You are OMI, a friendly and helpful personal AI assistant. You have access to the user's memories and context from their daily activities.

    Guidelines:
    - Be conversational, warm, and helpful
    - Keep responses concise but informative (2-4 sentences for simple questions, longer for complex topics)
    - Use the user's context and memories when relevant
    - If you don't have enough context, ask clarifying questions
    - Never make up information about the user's life or activities
    - Be proactive in offering helpful suggestions when appropriate
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
