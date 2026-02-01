import SwiftUI

// MARK: - Chat Session Model

/// A chat session that groups related messages
struct ChatSession: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var preview: String?
    let createdAt: Date
    var updatedAt: Date
    let appId: String?
    var messageCount: Int
    var starred: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, preview, starred
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case appId = "app_id"
        case messageCount = "message_count"
    }

    init(id: String = UUID().uuidString, title: String = "New Chat", preview: String? = nil,
         createdAt: Date = Date(), updatedAt: Date = Date(), appId: String? = nil,
         messageCount: Int = 0, starred: Bool = false) {
        self.id = id
        self.title = title
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.appId = appId
        self.messageCount = messageCount
        self.starred = starred
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        appId = try container.decodeIfPresent(String.self, forKey: .appId)
        messageCount = try container.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        starred = try container.decodeIfPresent(Bool.self, forKey: .starred) ?? false
    }
}

// MARK: - Chat Message Model

/// A single chat message
struct ChatMessage: Identifiable {
    var id: String  // Mutable to sync with server-generated ID
    var text: String
    let createdAt: Date
    let sender: ChatSender
    var isStreaming: Bool
    /// Rating: 1 = thumbs up, -1 = thumbs down, nil = no rating
    var rating: Int?
    /// Whether the message has been synced with the backend (has valid server ID)
    var isSynced: Bool

    init(id: String = UUID().uuidString, text: String, createdAt: Date = Date(), sender: ChatSender, isStreaming: Bool = false, rating: Int? = nil, isSynced: Bool = false) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sender = sender
        self.isStreaming = isStreaming
        self.rating = rating
        self.isSynced = isSynced
    }
}

enum ChatSender {
    case user
    case ai
}

/// State management for chat functionality with client-side Gemini
/// Uses hybrid architecture: Swift → Gemini for streaming, Backend for persistence + context
@MainActor
class ChatProvider: ObservableObject {
    // MARK: - Published State
    @Published var messages: [ChatMessage] = []
    @Published var sessions: [ChatSession] = []
    @Published var currentSession: ChatSession?
    @Published var isLoading = false
    @Published var isLoadingSessions = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var selectedAppId: String?
    @Published var hasMoreMessages = false
    @Published var isLoadingMoreMessages = false
    @Published var showStarredOnly = false
    @Published var searchQuery = ""

    private var geminiClient: GeminiClient?
    private let messagesPageSize = 50

    // MARK: - Filtered Sessions
    var filteredSessions: [ChatSession] {
        guard !searchQuery.isEmpty else { return sessions }
        let query = searchQuery.lowercased()
        return sessions.filter { session in
            session.title.lowercased().contains(query) ||
            (session.preview?.lowercased().contains(query) ?? false)
        }
    }

    // MARK: - Cached Context for Prompts
    private var cachedContext: ChatContextResponse?
    private var cachedMemories: [ServerMemory] = []
    private var memoriesLoaded = false

    // MARK: - Current Session ID
    var currentSessionId: String? {
        currentSession?.id
    }

    // MARK: - Current Model
    var currentModel: String {
        "Gemini 3 Pro"
    }

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

    // MARK: - Session Management

    /// Fetch all chat sessions for the current app
    func fetchSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }

        do {
            sessions = try await APIClient.shared.getChatSessions(
                appId: selectedAppId,
                starred: showStarredOnly ? true : nil
            )
            log("ChatProvider loaded \(sessions.count) sessions (starred filter: \(showStarredOnly))")

            // If we have sessions and no current session, select the most recent
            if currentSession == nil, let mostRecent = sessions.first {
                await selectSession(mostRecent)
            }
        } catch {
            logError("Failed to load chat sessions", error: error)
            sessions = []
        }
    }

    /// Toggle the starred filter and reload sessions
    func toggleStarredFilter() async {
        showStarredOnly.toggle()
        log("Toggled starred filter: \(showStarredOnly)")
        AnalyticsManager.shared.chatStarredFilterToggled(enabled: showStarredOnly)
        await fetchSessions()
    }

    /// Create a new chat session
    func createNewSession() async -> ChatSession? {
        do {
            let session = try await APIClient.shared.createChatSession(appId: selectedAppId)
            sessions.insert(session, at: 0)
            currentSession = session
            messages = []
            hasMoreMessages = false
            log("Created new chat session: \(session.id)")
            AnalyticsManager.shared.chatSessionCreated()

            // Generate initial greeting message
            await fetchInitialMessage(for: session)

            return session
        } catch {
            logError("Failed to create chat session", error: error)
            errorMessage = "Failed to create new chat"
            return nil
        }
    }

    /// Fetch and display an initial greeting message for a new session
    private func fetchInitialMessage(for session: ChatSession) async {
        do {
            let response = try await APIClient.shared.getInitialMessage(
                sessionId: session.id,
                appId: selectedAppId
            )

            // Add the AI greeting to messages (already has server ID)
            let greetingMessage = ChatMessage(
                id: response.messageId,
                text: response.message,
                createdAt: Date(),
                sender: .ai,
                isStreaming: false,
                rating: nil,
                isSynced: true
            )
            messages.append(greetingMessage)

            // Update session preview
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index].preview = response.message
            }

            // Track analytics
            AnalyticsManager.shared.initialMessageGenerated(hasApp: selectedAppId != nil)

            log("Added initial greeting message for session \(session.id)")
        } catch {
            // Non-fatal: session still works without greeting
            logError("Failed to fetch initial message", error: error)
        }
    }

    /// Select a session and load its messages
    func selectSession(_ session: ChatSession) async {
        guard currentSession?.id != session.id else { return }

        currentSession = session
        isLoading = true
        errorMessage = nil
        hasMoreMessages = false

        do {
            let persistedMessages = try await APIClient.shared.getMessages(
                sessionId: session.id,
                limit: messagesPageSize
            )
            messages = persistedMessages.map { dbMessage in
                ChatMessage(
                    id: dbMessage.id,
                    text: dbMessage.text,
                    createdAt: dbMessage.createdAt,
                    sender: dbMessage.sender == "human" ? .user : .ai,
                    isStreaming: false,
                    rating: dbMessage.rating,
                    isSynced: true  // Messages from backend have valid server IDs
                )
            }
            // If we got a full page, there might be more messages
            hasMoreMessages = persistedMessages.count == messagesPageSize
            log("ChatProvider loaded \(messages.count) messages for session \(session.id), hasMore: \(hasMoreMessages)")
        } catch {
            logError("Failed to load messages for session", error: error)
            messages = []
        }

        isLoading = false
    }

    /// Load more (older) messages for the current session
    func loadMoreMessages() async {
        guard let sessionId = currentSessionId,
              hasMoreMessages,
              !isLoadingMoreMessages else { return }

        isLoadingMoreMessages = true

        do {
            let offset = messages.count
            let olderMessages = try await APIClient.shared.getMessages(
                sessionId: sessionId,
                limit: messagesPageSize,
                offset: offset
            )

            let newMessages = olderMessages.map { dbMessage in
                ChatMessage(
                    id: dbMessage.id,
                    text: dbMessage.text,
                    createdAt: dbMessage.createdAt,
                    sender: dbMessage.sender == "human" ? .user : .ai,
                    isStreaming: false,
                    rating: dbMessage.rating,
                    isSynced: true  // Messages from backend have valid server IDs
                )
            }

            // Append older messages (they come in ascending order, so append at end)
            messages.append(contentsOf: newMessages)

            // Check if there are more
            hasMoreMessages = olderMessages.count == messagesPageSize
            log("Loaded \(newMessages.count) more messages, total: \(messages.count), hasMore: \(hasMoreMessages)")
        } catch {
            logError("Failed to load more messages", error: error)
        }

        isLoadingMoreMessages = false
    }

    /// Delete a chat session
    func deleteSession(_ session: ChatSession) async {
        do {
            try await APIClient.shared.deleteChatSession(sessionId: session.id)
            sessions.removeAll { $0.id == session.id }

            // If deleted the current session, select another or clear
            if currentSession?.id == session.id {
                if let nextSession = sessions.first {
                    await selectSession(nextSession)
                } else {
                    currentSession = nil
                    messages = []
                }
            }

            log("Deleted chat session: \(session.id)")
            AnalyticsManager.shared.chatSessionDeleted()
        } catch {
            logError("Failed to delete chat session", error: error)
            errorMessage = "Failed to delete chat"
        }
    }

    /// Toggle starred status for a session
    func toggleStarred(_ session: ChatSession) async {
        do {
            let updated = try await APIClient.shared.updateChatSession(
                sessionId: session.id,
                starred: !session.starred
            )

            // Update in sessions list
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = updated
            }

            // Update current session if it's the same
            if currentSession?.id == session.id {
                currentSession = updated
            }

            log("Toggled starred for session \(session.id): \(updated.starred)")
        } catch {
            logError("Failed to toggle starred", error: error)
        }
    }

    /// Update session title (user-initiated rename)
    func updateSessionTitle(_ session: ChatSession, title: String) async {
        do {
            let updated = try await APIClient.shared.updateChatSession(
                sessionId: session.id,
                title: title
            )

            // Update in sessions list
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = updated
            }

            // Update current session if it's the same
            if currentSession?.id == session.id {
                currentSession = updated
            }

            log("Updated title for session \(session.id): \(title)")
            AnalyticsManager.shared.sessionRenamed()
        } catch {
            logError("Failed to update session title", error: error)
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

    // MARK: - Fetch Context from Backend

    /// Fetches rich context (conversations + memories) from backend using LLM-based retrieval
    private func fetchContext(for question: String) async -> String {
        // Build previous messages for context
        let previousMessages: [(text: String, sender: String)] = messages.suffix(10).map { msg in
            (text: msg.text, sender: msg.sender == .user ? "human" : "ai")
        }

        do {
            let context = try await APIClient.shared.getChatContext(
                question: question,
                timezone: TimeZone.current.identifier,
                appId: selectedAppId,
                previousMessages: previousMessages
            )

            cachedContext = context

            if context.requiresContext {
                log("ChatProvider fetched context: \(context.conversations.count) conversations, \(context.memories.count) memories")
                return context.contextString
            } else {
                log("ChatProvider: question doesn't require context")
                // Return just memories for personalization
                return context.contextString
            }
        } catch {
            logError("Failed to fetch chat context", error: error)
            // Fall back to cached memories
            return formatMemoriesSection()
        }
    }

    // MARK: - Build System Prompt with Variables

    /// Builds the system prompt with dynamic template variables
    private func buildSystemPrompt(contextString: String) -> String {
        // Get user name from AuthService
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName

        // Use the context string from backend (includes memories + conversations)
        // Fall back to just memories if context is empty
        let contextSection = contextString.isEmpty ? formatMemoriesSection() : contextString

        // Use ChatPromptBuilder to build the prompt with all variables
        return ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: contextSection
        )
    }

    /// Builds system prompt using cached memories only (for simple messages)
    private func buildSystemPromptSimple() -> String {
        let userName = AuthService.shared.displayName.isEmpty ? "there" : AuthService.shared.givenName
        let memoriesSection = formatMemoriesSection()

        return ChatPromptBuilder.buildDesktopChat(
            userName: userName,
            memoriesSection: memoriesSection
        )
    }

    // MARK: - Fetch Messages

    /// Fetch chat messages from backend and load context
    /// This is called when no session is selected (legacy mode) or for initial load
    func fetchMessages() async {
        isLoading = true
        errorMessage = nil

        // If we have a current session, load its messages
        if let session = currentSession {
            await selectSession(session)
        } else {
            // Legacy mode: load messages without session
            do {
                let persistedMessages = try await APIClient.shared.getMessages(appId: selectedAppId, limit: 100)
                messages = persistedMessages.map { dbMessage in
                    ChatMessage(
                        id: dbMessage.id,
                        text: dbMessage.text,
                        createdAt: dbMessage.createdAt,
                        sender: dbMessage.sender == "human" ? .user : .ai,
                        isStreaming: false,
                        rating: dbMessage.rating,
                        isSynced: true  // Messages from backend have valid server IDs
                    )
                }
                log("ChatProvider loaded \(messages.count) persisted messages")
            } catch {
                logError("Failed to load persisted messages", error: error)
                messages.removeAll()
            }
        }

        // Load memories for context (non-blocking, best-effort)
        await loadMemoriesIfNeeded()

        isLoading = false
    }

    /// Initialize chat: fetch sessions and load messages
    func initialize() async {
        await fetchSessions()
        await loadMemoriesIfNeeded()
    }

    // MARK: - Send Message

    /// Send a message and get AI response with tool calling support
    /// Persists both user and AI messages to backend
    func sendMessage(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        guard let client = geminiClient else {
            errorMessage = "AI not available"
            return
        }

        // If no session exists, create one first
        if currentSession == nil {
            _ = await createNewSession()
        }

        guard let sessionId = currentSessionId else {
            errorMessage = "Failed to create chat session"
            return
        }

        isSending = true
        errorMessage = nil

        // Save user message to backend (fire and forget - don't block UI)
        let userMessageId = UUID().uuidString
        let isFirstMessage = messages.isEmpty
        Task { [weak self] in
            do {
                let response = try await APIClient.shared.saveMessage(
                    text: trimmedText,
                    sender: "human",
                    appId: selectedAppId,
                    sessionId: sessionId
                )
                // Sync local message ID with server ID
                await MainActor.run {
                    if let index = self?.messages.firstIndex(where: { $0.id == userMessageId }) {
                        self?.messages[index].id = response.id
                        self?.messages[index].isSynced = true
                    }
                }
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

        // Create placeholder AI message
        let aiMessageId = UUID().uuidString
        let aiMessage = ChatMessage(
            id: aiMessageId,
            text: "",
            sender: .ai,
            isStreaming: true
        )
        messages.append(aiMessage)

        do {
            // Fetch context from backend (LLM determines if context is needed)
            let contextString = await fetchContext(for: trimmedText)

            // Build chat history for Gemini
            let chatHistory = buildChatHistory()

            // Build system prompt with fetched context
            let systemPrompt = buildSystemPrompt(contextString: contextString)

            // First, try tool-enabled request to see if tools are needed
            let result = try await client.sendToolChatRequest(
                messages: chatHistory,
                systemPrompt: systemPrompt,
                tools: GeminiClient.chatTools
            )

            var finalResponse: String

            if result.requiresToolExecution && !result.toolCalls.isEmpty {
                // Execute tool calls
                log("Executing \(result.toolCalls.count) tool call(s)")
                updateMessage(id: aiMessageId, text: "Using tools...")

                let toolResults = await ChatToolExecutor.executeAll(result.toolCalls)

                // Continue with tool results to get final response
                finalResponse = try await client.continueWithToolResults(
                    originalMessages: chatHistory,
                    toolCalls: result.toolCalls,
                    toolResults: toolResults,
                    systemPrompt: systemPrompt
                )
            } else {
                // No tools needed, use direct response
                finalResponse = result.text
            }

            // Update AI message with final response
            updateMessage(id: aiMessageId, text: finalResponse)

            // Mark streaming complete (but not synced yet - rating disabled until synced)
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                messages[index].isStreaming = false

                // Save AI response to backend and sync ID (awaited, not fire-and-forget)
                let aiResponseText = messages[index].text
                if !aiResponseText.isEmpty {
                    do {
                        let response = try await APIClient.shared.saveMessage(
                            text: aiResponseText,
                            sender: "ai",
                            appId: selectedAppId,
                            sessionId: sessionId
                        )
                        // Sync local message with server response (like Flutter does)
                        if let syncIndex = messages.firstIndex(where: { $0.id == aiMessageId }) {
                            messages[syncIndex].id = response.id
                            messages[syncIndex].isSynced = true
                        }
                        log("Saved and synced AI response: \(response.id)")
                    } catch {
                        logError("Failed to persist AI response", error: error)
                        // Message remains unsynced - rating will be disabled
                    }
                }
            }

            // Auto-generate title after first exchange (user message + AI response)
            if isFirstMessage {
                await generateSessionTitle(sessionId: sessionId)
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

    /// Generate a title for the session using LLM
    private func generateSessionTitle(sessionId: String) async {
        // Need at least 2 messages (user + AI) for meaningful title
        guard messages.count >= 2 else {
            log("Not enough messages for title generation")
            return
        }

        // Convert messages to the format expected by the API
        let messageTuples: [(text: String, sender: String)] = messages.map { msg in
            (text: msg.text, sender: msg.sender == .user ? "human" : "ai")
        }

        do {
            let response = try await APIClient.shared.generateSessionTitle(
                sessionId: sessionId,
                messages: messageTuples
            )

            // Update session in list
            if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
                sessions[index].title = response.title
            }

            // Update current session
            if currentSession?.id == sessionId {
                currentSession?.title = response.title
            }

            log("Generated session title: \(response.title)")
            AnalyticsManager.shared.sessionTitleGenerated()
        } catch {
            logError("Failed to generate session title", error: error)
            // Non-fatal - session continues with default title
        }
    }

    /// Update message text (replaces entire text)
    private func updateMessage(id: String, text: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = text
        }
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

    // MARK: - Message Rating

    /// Rate a message (thumbs up/down)
    /// - Parameters:
    ///   - messageId: The message ID to rate
    ///   - rating: 1 for thumbs up, -1 for thumbs down, nil to clear rating
    func rateMessage(_ messageId: String, rating: Int?) async {
        // Update local state immediately for responsive UI
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].rating = rating
        }

        // Persist to backend
        do {
            try await APIClient.shared.rateMessage(messageId: messageId, rating: rating)
            log("Rated message \(messageId) with rating: \(String(describing: rating))")

            // Track analytics
            if let rating = rating {
                AnalyticsManager.shared.messageRated(rating: rating)
            }
        } catch {
            logError("Failed to rate message", error: error)
            // Revert local state on failure
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].rating = nil
            }
        }
    }

    // MARK: - Clear Chat

    /// Clear current session messages (delete and create new)
    func clearChat() async {
        // If we have a current session, delete it and create a new one
        if let session = currentSession {
            await deleteSession(session)
        }

        // Create a fresh session
        _ = await createNewSession()

        log("Chat cleared")
        AnalyticsManager.shared.chatCleared()
    }

    // MARK: - App Selection

    /// Select a chat app and load its sessions
    func selectApp(_ appId: String?) async {
        guard selectedAppId != appId else { return }
        selectedAppId = appId
        currentSession = nil
        messages = []
        sessions = []
        errorMessage = nil

        // Load sessions for the selected app
        await fetchSessions()
    }

    // MARK: - Session Grouping Helpers

    /// Group sessions by date for sidebar display (uses filteredSessions for search)
    var groupedSessions: [(String, [ChatSession])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var older: [ChatSession] = []

        for session in filteredSessions {
            if calendar.isDateInToday(session.updatedAt) {
                today.append(session)
            } else if calendar.isDateInYesterday(session.updatedAt) {
                yesterday.append(session)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      session.updatedAt > weekAgo {
                thisWeek.append(session)
            } else {
                older.append(session)
            }
        }

        var groups: [(String, [ChatSession])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !older.isEmpty { groups.append(("Older", older)) }

        return groups
    }
}
