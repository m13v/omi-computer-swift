import SwiftUI

/// State management for chat functionality
@MainActor
class ChatProvider: ObservableObject {
    @Published var messages: [ServerChatMessage] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var selectedAppId: String?

    private let apiClient = APIClient.shared

    // MARK: - Fetch Messages

    /// Fetch chat messages for the current app
    func fetchMessages() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            messages = try await apiClient.getChatMessages(appId: selectedAppId, limit: 100)
            log("Fetched \(messages.count) messages for app: \(selectedAppId ?? "default")")
        } catch {
            logError("Failed to fetch messages", error: error)
            errorMessage = "Failed to load messages: \(error.localizedDescription)"
        }
    }

    // MARK: - Send Message

    /// Send a message and get AI response
    func sendMessage(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        isSending = true
        errorMessage = nil
        defer { isSending = false }

        // Add optimistic human message
        let tempHumanMessage = ServerChatMessage(
            id: UUID().uuidString,
            text: trimmedText,
            createdAt: Date(),
            sender: .human,
            appId: selectedAppId,
            type: .text,
            memoriesId: [],
            chatSessionId: nil
        )
        messages.append(tempHumanMessage)

        do {
            // Send message and get AI response
            let aiResponse = try await apiClient.sendChatMessage(text: trimmedText, appId: selectedAppId)

            // The API returns only the AI response, so we keep the human message and add AI response
            messages.append(aiResponse)

            log("Sent message, received AI response")
        } catch {
            // Remove optimistic message on error
            messages.removeAll { $0.id == tempHumanMessage.id }

            logError("Failed to send message", error: error)
            errorMessage = "Failed to send message: \(error.localizedDescription)"
        }
    }

    // MARK: - Clear Chat

    /// Clear all messages and get initial greeting
    func clearChat() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await apiClient.clearChatMessages(appId: selectedAppId)
            messages.removeAll()

            // Add initial greeting if provided
            if let initialMessage = response.initialMessage {
                messages.append(initialMessage)
            }

            log("Cleared \(response.deletedCount) messages")
        } catch {
            logError("Failed to clear chat", error: error)
            errorMessage = "Failed to clear chat: \(error.localizedDescription)"
        }
    }

    // MARK: - App Selection

    /// Select a chat app
    func selectApp(_ appId: String?) {
        guard selectedAppId != appId else { return }
        selectedAppId = appId
        messages.removeAll()

        // Fetch messages for the new app
        Task {
            await fetchMessages()
        }
    }
}
