import SwiftUI
import Combine

/// Manages task-scoped chat sessions using the shared ChatProvider.
/// Saves/restores ChatProvider state when entering/leaving task chat
/// so the main Chat tab remains unaffected.
@MainActor
class TaskChatCoordinator: ObservableObject {
    @Published var activeTaskId: String?
    @Published var isPanelOpen = false
    @Published var isOpening = false

    /// Text to pre-fill in the chat input field (consumed by the UI).
    @Published var pendingInputText: String = ""

    /// The workspace path used for file-system tools in task chat
    @Published var workspacePath: String = TaskAgentSettings.shared.workingDirectory

    private let chatProvider: ChatProvider

    /// Saved state from before we switched to task chat
    private var savedSession: ChatSession?
    private var savedMessages: [ChatMessage] = []
    private var savedIsInDefaultChat = true
    private var savedWorkingDirectory: String?
    private var savedOverrideAppId: String?

    /// App ID used to isolate task chat messages from the default chat
    static let taskChatAppId = "task-chat"

    init(chatProvider: ChatProvider) {
        self.chatProvider = chatProvider
    }

    /// Open (or resume) a chat panel for a task.
    /// Creates a new Firestore ChatSession if the task doesn't have one yet.
    /// The initial prompt is placed in `pendingInputText` for the user to review before sending.
    func openChat(for task: TaskActionItem) async {
        log("TaskChatCoordinator: openChat for \(task.id), activeTaskId=\(activeTaskId ?? "nil"), isPanelOpen=\(isPanelOpen), isOpening=\(isOpening)")

        // If already viewing this task's chat, re-establish ChatProvider state
        // (another page may have changed the shared provider while we were away)
        if activeTaskId == task.id {
            log("TaskChatCoordinator: same task, restoring provider state")
            chatProvider.overrideAppId = Self.taskChatAppId
            if let sessionId = task.chatSessionId {
                let session = ChatSession(id: sessionId, title: taskChatTitle(for: task))
                await chatProvider.selectSession(session, force: true)
            }
            isPanelOpen = true
            return
        }

        // Prevent duplicate open calls while one is in progress
        guard !isOpening else {
            log("TaskChatCoordinator: already opening, skipping")
            return
        }
        isOpening = true
        defer { isOpening = false }

        // Stop any in-progress streaming before switching sessions
        if chatProvider.isSending {
            log("TaskChatCoordinator: stopping active stream before switching tasks")
            chatProvider.stopAgent()
        }

        // Save current ChatProvider state on first open
        if activeTaskId == nil {
            savedSession = chatProvider.currentSession
            savedMessages = chatProvider.messages
            savedIsInDefaultChat = chatProvider.isInDefaultChat
            savedWorkingDirectory = chatProvider.workingDirectory
            savedOverrideAppId = chatProvider.overrideAppId
        }

        activeTaskId = task.id

        // Set workspace path for file-system tools (only if explicitly configured)
        let configuredPath = TaskAgentSettings.shared.workingDirectory
        if !configuredPath.isEmpty {
            workspacePath = configuredPath
            chatProvider.workingDirectory = workspacePath
        }
        // Isolate task messages from the default chat
        chatProvider.overrideAppId = Self.taskChatAppId

        // Check if task already has a chat session with messages
        var needsNewSession = true
        if let sessionId = task.chatSessionId {
            // Try to resume existing session
            let session = ChatSession(id: sessionId, title: taskChatTitle(for: task))
            await chatProvider.selectSession(session)

            if !chatProvider.messages.isEmpty {
                // Session has messages, resume it
                needsNewSession = false
            } else {
                log("TaskChatCoordinator: session \(sessionId) is empty (previous attempt failed), creating new session")
            }
        }

        if needsNewSession {
            // Create a fresh session for this task
            if let session = await chatProvider.createNewSession(title: taskChatTitle(for: task), skipGreeting: true, appId: "task-chat") {
                // Persist the session ID to the task's local storage
                try? await ActionItemStorage.shared.updateChatSessionId(
                    taskId: task.id,
                    sessionId: session.id
                )
                // Also update the in-memory task in the store
                TasksStore.shared.updateChatSessionId(taskId: task.id, sessionId: session.id)

                // Pre-fill the input with context so the user can review before sending
                pendingInputText = buildInitialPrompt(for: task)
            }
        }

        isPanelOpen = true
    }

    /// Switch the chat panel to a different task's session.
    func switchToTask(_ task: TaskActionItem) async {
        guard task.id != activeTaskId else { return }
        await openChat(for: task)
    }

    /// Close the task chat panel and restore previous ChatProvider state.
    func closeChat() async {
        // Stop any in-progress streaming before closing
        if chatProvider.isSending {
            log("TaskChatCoordinator: stopping active stream before closing")
            chatProvider.stopAgent()
        }

        isPanelOpen = false
        activeTaskId = nil
        pendingInputText = ""

        // Restore previous ChatProvider state
        chatProvider.workingDirectory = savedWorkingDirectory
        chatProvider.overrideAppId = savedOverrideAppId
        if savedIsInDefaultChat {
            await chatProvider.switchToDefaultChat()
        } else if let saved = savedSession {
            await chatProvider.selectSession(saved)
        }

        savedSession = nil
        savedMessages = []
        savedIsInDefaultChat = true
        savedWorkingDirectory = nil
        savedOverrideAppId = nil
    }

    /// Build the initial context prompt for a task chat session.
    /// Uses the same shared prompt as the tmux agent (TaskAgentSettings.buildTaskPrompt).
    private func buildInitialPrompt(for task: TaskActionItem) -> String {
        TaskAgentSettings.shared.buildTaskPrompt(for: task)
    }

    private func taskChatTitle(for task: TaskActionItem) -> String {
        let desc = task.description
        let maxLen = 40
        if desc.count > maxLen {
            return String(desc.prefix(maxLen)) + "..."
        }
        return desc
    }
}
