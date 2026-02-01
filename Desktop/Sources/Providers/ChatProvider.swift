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
/// Uses hybrid architecture: Swift → Gemini for streaming, Backend for persistence
@MainActor
class ChatProvider: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var selectedAppId: String?

    private var geminiClient: GeminiClient?

    // MARK: - Cached Context for Prompts
    private var cachedMemories: [ServerMemory] = []
    private var memoriesLoaded = false

    // MARK: - Session ID for message grouping
    private let sessionId: String = UUID().uuidString

    // MARK: - System Prompt
    // Prompts are defined in ChatPrompts.swift (converted from Python backend)

    init() {
        do {
            self.geminiClient = try GeminiClient(model: "gemini-3-pro-preview")
            log("ChatProvider initialized with Gemini client")
        } catch {
            logError("Failed to initialize Gemini client", error: error)
            self.errorMessage = "AI not available: \(error.localizedDescription)"
        }
    }

    // MARK: - Load Context (Memories)

    /// Fetches user memories from the backend for use in prompts
    private func loadMemoriesIfNeeded() async {
        guard !memoriesLoaded else { return }

        do {
            cachedMemories = try await APIClient.shared.getMemories(limit: 50)
            memoriesLoaded = true
            log("ChatProvider loaded \(cachedMemories.count) memories for context")
        } catch {
            logError("Failed to load memories for chat context", error: error)
            // Continue without memories - non-critical
        }
    }

    /// Formats cached memories into a string for the prompt
    private func formatMemoriesSection() -> String {
        guard !cachedMemories.isEmpty else { return "" }

        let userName = AuthService.shared.displayName.isEmpty ? "the user" : AuthService.shared.givenName

        var lines: [String] = ["<user_facts>", "Facts about \(userName):"]
        for memory in cachedMemories.prefix(30) {  // Limit to 30 most relevant
            lines.append("- \(memory.content)")
        }
        lines.append("</user_facts>")

        return lines.joined(separator: "\n")
    }

    // MARK: - Build System Prompt with Variables

    /// Builds the system prompt with dynamic template variables
    private func buildSystemPrompt() -> String {
        // Get user name from AuthService
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName

        // Build memories section from cached memories
        let memoriesSection = formatMemoriesSection()

        // Use ChatPromptBuilder to build the prompt with all variables
        return ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: memoriesSection
        )
    }

    // MARK: - Fetch Messages

    /// Fetch chat messages from backend and load context
    func fetchMessages() async {
        isLoading = true
        errorMessage = nil

        // Load persisted messages from backend
        do {
            let persistedMessages = try await APIClient.shared.getMessages(appId: selectedAppId, limit: 100)
            messages = persistedMessages.map { dbMessage in
                ChatMessage(
                    id: dbMessage.id,
                    text: dbMessage.text,
                    createdAt: dbMessage.createdAt,
                    sender: dbMessage.sender == "human" ? .user : .ai,
                    isStreaming: false
                )
            }
            log("ChatProvider loaded \(messages.count) persisted messages")
        } catch {
            logError("Failed to load persisted messages", error: error)
            // Continue without persisted messages - start fresh
            messages.removeAll()
        }

        // Load memories for context (non-blocking, best-effort)
        await loadMemoriesIfNeeded()

        isLoading = false
    }

    // MARK: - Send Message

    /// Send a message and get streaming AI response
    /// Persists both user and AI messages to backend
    func sendMessage(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        guard let client = geminiClient else {
            errorMessage = "AI not available"
            return
        }

        isSending = true
        errorMessage = nil

        // Save user message to backend (fire and forget - don't block UI)
        let userMessageId = UUID().uuidString
        Task {
            do {
                let response = try await APIClient.shared.saveMessage(
                    text: trimmedText,
                    sender: "human",
                    appId: selectedAppId,
                    sessionId: sessionId
                )
                log("Saved user message to backend: \(response.id)")
            } catch {
                logError("Failed to persist user message", error: error)
                // Non-critical - continue with chat
            }
        }

        // Add user message to UI
        let userMessage = ChatMessage(
            id: userMessageId,
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

                // Save AI response to backend
                let aiResponseText = messages[index].text
                if !aiResponseText.isEmpty {
                    Task {
                        do {
                            let response = try await APIClient.shared.saveMessage(
                                text: aiResponseText,
                                sender: "ai",
                                appId: self.selectedAppId,
                                sessionId: self.sessionId
                            )
                            log("Saved AI response to backend: \(response.id)")
                        } catch {
                            logError("Failed to persist AI response", error: error)
                            // Non-critical - continue
                        }
                    }
                }
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

    /// Clear all messages (local and backend)
    func clearChat() async {
        messages.removeAll()
        errorMessage = nil

        // Clear from backend (fire and forget)
        Task {
            do {
                let response = try await APIClient.shared.deleteMessages(appId: selectedAppId)
                log("Cleared \(response.deletedCount ?? 0) messages from backend")
            } catch {
                logError("Failed to clear messages from backend", error: error)
                // Non-critical - local clear still works
            }
        }

        log("Chat cleared")
        AnalyticsManager.shared.chatCleared()
    }

    // MARK: - App Selection

    /// Select a chat app and load its message history
    func selectApp(_ appId: String?) async {
        guard selectedAppId != appId else { return }
        selectedAppId = appId
        errorMessage = nil

        // Load messages for the selected app
        await fetchMessages()
    }
}
