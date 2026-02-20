import SwiftUI
import Combine

/// Per-task chat state with its own bridge process and message history.
/// Each task chat is fully independent — no shared state with the sidebar chat.
/// Uses Claude SDK's native `resume: sessionId` for conversation persistence.
@MainActor
class TaskChatState: ObservableObject {
    let taskId: String

    @Published var messages: [ChatMessage] = []
    @Published var isSending = false
    @Published var isStopping = false
    @Published var draftText = ""
    @Published var errorMessage: String?
    @Published var chatMode: ChatMode = .act

    /// Own bridge process — completely independent from sidebar chat
    private let bridge = ClaudeAgentBridge()
    private var bridgeStarted = false

    /// Claude SDK session ID for resume (conversation continuity)
    var claudeSessionId: String?

    /// Workspace path for file-system tools
    let workspacePath: String

    /// Closure to build system prompt from ChatProvider's cached data
    var systemPromptBuilder: (() -> String)?

    /// Follow-up chaining
    private var pendingFollowUpText: String?

    // MARK: - Streaming Buffers (mirrored from ChatProvider)

    private var streamingTextBuffer: String = ""
    private var streamingThinkingBuffer: String = ""
    private var streamingBufferMessageId: String?
    private var streamingFlushWorkItem: DispatchWorkItem?
    private let streamingFlushInterval: TimeInterval = 0.1

    init(taskId: String, workspacePath: String) {
        self.taskId = taskId
        self.workspacePath = workspacePath
    }

    deinit {
        // Fire-and-forget bridge cleanup
        let bridge = self.bridge
        Task { await bridge.stop() }
    }

    // MARK: - Bridge Lifecycle

    private func ensureBridgeStarted() async -> Bool {
        if bridgeStarted {
            let alive = await bridge.isAlive
            if !alive {
                log("TaskChatState[\(taskId)]: Bridge process died, will restart")
                bridgeStarted = false
                // Session is lost when bridge dies
                claudeSessionId = nil
            }
        }
        guard !bridgeStarted else { return true }
        do {
            try await bridge.start()
            bridgeStarted = true
            log("TaskChatState[\(taskId)]: Bridge started")
            return true
        } catch {
            logError("TaskChatState[\(taskId)]: Failed to start bridge", error: error)
            errorMessage = "AI not available: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Send Message

    func sendMessage(_ text: String, isFollowUp: Bool = false) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        guard !isSending else {
            log("TaskChatState[\(taskId)]: sendMessage called while already sending, ignoring")
            return
        }

        guard await ensureBridgeStarted() else { return }

        isSending = true
        errorMessage = nil

        // Add user message to local messages (no backend save)
        // Skip for follow-ups — sendFollowUp() already added it
        if !isFollowUp {
            let userMessage = ChatMessage(
                id: UUID().uuidString,
                text: trimmedText,
                sender: .user
            )
            messages.append(userMessage)
        }

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
            let systemPrompt = systemPromptBuilder?() ?? ""

            let queryResult = try await bridge.query(
                prompt: trimmedText,
                systemPrompt: systemPrompt,
                cwd: workspacePath.isEmpty ? nil : workspacePath,
                mode: chatMode.rawValue,
                resume: claudeSessionId,
                onTextDelta: { [weak self] delta in
                    Task { @MainActor [weak self] in
                        self?.appendToMessage(id: aiMessageId, text: delta)
                    }
                },
                onToolCall: { callId, name, input in
                    let toolCall = ToolCall(name: name, arguments: input, thoughtSignature: nil)
                    let result = await ChatToolExecutor.execute(toolCall)
                    log("TaskChat OMI tool \(name) executed for callId=\(callId)")
                    return result
                },
                onToolActivity: { [weak self] name, status, toolUseId, input in
                    Task { @MainActor [weak self] in
                        self?.addToolActivity(
                            messageId: aiMessageId,
                            toolName: name,
                            status: status == "started" ? .running : .completed,
                            toolUseId: toolUseId,
                            input: input
                        )
                    }
                },
                onThinkingDelta: { [weak self] text in
                    Task { @MainActor [weak self] in
                        self?.appendThinking(messageId: aiMessageId, text: text)
                    }
                },
                onToolResultDisplay: { [weak self] toolUseId, name, output in
                    Task { @MainActor [weak self] in
                        self?.addToolResult(messageId: aiMessageId, toolUseId: toolUseId, name: name, output: output)
                    }
                }
            )

            // Flush remaining streaming buffers
            streamingFlushWorkItem?.cancel()
            streamingFlushWorkItem = nil
            flushStreamingBuffer()

            // Capture session ID for resume on next message
            if !queryResult.sessionId.isEmpty {
                claudeSessionId = queryResult.sessionId
                log("TaskChatState[\(taskId)]: captured sessionId=\(queryResult.sessionId)")
            }

            // Finalize AI message
            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                let messageText = messages[index].text.isEmpty ? queryResult.text : messages[index].text
                messages[index].text = messageText
                messages[index].isStreaming = false
                completeRemainingToolCalls(messageId: aiMessageId)
            }

            log("TaskChatState[\(taskId)]: response complete (cost=$\(queryResult.costUsd))")
        } catch {
            streamingFlushWorkItem?.cancel()
            streamingFlushWorkItem = nil
            flushStreamingBuffer()

            if let index = messages.firstIndex(where: { $0.id == aiMessageId }) {
                if messages[index].text.isEmpty && messages[index].contentBlocks.isEmpty {
                    messages.remove(at: index)
                } else {
                    messages[index].isStreaming = false
                    completeRemainingToolCalls(messageId: aiMessageId)
                }
            }

            if let bridgeError = error as? BridgeError, case .stopped = bridgeError {
                // User stopped — no error
            } else {
                errorMessage = error.localizedDescription
            }
            logError("TaskChatState[\(taskId)]: query failed", error: error)
        }

        isSending = false
        isStopping = false

        // Chain follow-up if queued
        if let followUp = pendingFollowUpText {
            pendingFollowUpText = nil
            await sendMessage(followUp, isFollowUp: true)
        }
    }

    // MARK: - Follow-Up

    func sendFollowUp(_ text: String) async {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, isSending else { return }

        // Add user message locally
        let userMessage = ChatMessage(
            id: UUID().uuidString,
            text: trimmedText,
            sender: .user
        )
        messages.append(userMessage)

        // Queue follow-up and interrupt current query
        pendingFollowUpText = trimmedText
        await bridge.interrupt()
        log("TaskChatState[\(taskId)]: follow-up queued, interrupt sent")
    }

    // MARK: - Stop

    func stopAgent() {
        guard isSending else { return }
        isStopping = true
        Task {
            await bridge.interrupt()
        }
    }

    // MARK: - Streaming Helpers (mirrored from ChatProvider)

    private func appendToMessage(id: String, text: String) {
        streamingBufferMessageId = id
        streamingTextBuffer += text

        if streamingFlushWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushStreamingBuffer()
            }
            streamingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingFlushInterval, execute: workItem)
        }
    }

    private func flushStreamingBuffer() {
        streamingFlushWorkItem = nil

        guard let id = streamingBufferMessageId,
              let index = messages.firstIndex(where: { $0.id == id }) else {
            streamingTextBuffer = ""
            streamingThinkingBuffer = ""
            return
        }

        if !streamingTextBuffer.isEmpty {
            let buffered = streamingTextBuffer
            streamingTextBuffer = ""

            messages[index].text += buffered

            if let lastBlockIndex = messages[index].contentBlocks.indices.last,
               case .text(let blockId, let existing) = messages[index].contentBlocks[lastBlockIndex] {
                messages[index].contentBlocks[lastBlockIndex] = .text(id: blockId, text: existing + buffered)
            } else {
                messages[index].contentBlocks.append(.text(id: UUID().uuidString, text: buffered))
            }
        }

        if !streamingThinkingBuffer.isEmpty {
            let buffered = streamingThinkingBuffer
            streamingThinkingBuffer = ""

            if let lastBlockIndex = messages[index].contentBlocks.indices.last,
               case .thinking(let thinkId, let existing) = messages[index].contentBlocks[lastBlockIndex] {
                messages[index].contentBlocks[lastBlockIndex] = .thinking(id: thinkId, text: existing + buffered)
            } else {
                messages[index].contentBlocks.append(.thinking(id: UUID().uuidString, text: buffered))
            }
        }
    }

    private func addToolActivity(messageId: String, toolName: String, status: ToolCallStatus, toolUseId: String? = nil, input: [String: Any]? = nil) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        let toolInput = input.flatMap { ChatContentBlock.toolInputSummary(for: toolName, input: $0) }

        if status == .running {
            if let toolUseId = toolUseId, toolInput != nil {
                for i in stride(from: messages[index].contentBlocks.count - 1, through: 0, by: -1) {
                    if case .toolCall(let id, let name, let st, let existingTuid, _, let output) = messages[index].contentBlocks[i],
                       (existingTuid == toolUseId || (existingTuid == nil && name == toolName && st == .running)) {
                        messages[index].contentBlocks[i] = .toolCall(
                            id: id, name: name, status: st,
                            toolUseId: toolUseId, input: toolInput, output: output
                        )
                        return
                    }
                }
            }
            messages[index].contentBlocks.append(
                .toolCall(id: UUID().uuidString, name: toolName, status: .running,
                          toolUseId: toolUseId, input: toolInput)
            )
        } else {
            for i in stride(from: messages[index].contentBlocks.count - 1, through: 0, by: -1) {
                if case .toolCall(let id, let name, .running, let existingTuid, let existingInput, let output) = messages[index].contentBlocks[i] {
                    let matches = (toolUseId != nil && existingTuid == toolUseId) || (toolUseId == nil && name == toolName)
                    if matches {
                        messages[index].contentBlocks[i] = .toolCall(
                            id: id, name: name, status: .completed,
                            toolUseId: toolUseId ?? existingTuid,
                            input: toolInput ?? existingInput,
                            output: output
                        )
                        break
                    }
                }
            }
        }
    }

    private func addToolResult(messageId: String, toolUseId: String, name: String, output: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }

        for i in messages[index].contentBlocks.indices {
            if case .toolCall(let id, let blockName, let status, let tuid, let input, _) = messages[index].contentBlocks[i],
               (tuid == toolUseId || (tuid == nil && blockName == name)) {
                messages[index].contentBlocks[i] = .toolCall(
                    id: id, name: blockName, status: status,
                    toolUseId: toolUseId, input: input, output: output
                )
                return
            }
        }
    }

    private func appendThinking(messageId: String, text: String) {
        streamingBufferMessageId = messageId
        streamingThinkingBuffer += text

        if streamingFlushWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.flushStreamingBuffer()
            }
            streamingFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + streamingFlushInterval, execute: workItem)
        }
    }

    private func completeRemainingToolCalls(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        for i in messages[index].contentBlocks.indices {
            if case .toolCall(let id, let name, .running, let toolUseId, let input, let output) = messages[index].contentBlocks[i] {
                messages[index].contentBlocks[i] = .toolCall(
                    id: id, name: name, status: .completed,
                    toolUseId: toolUseId, input: input, output: output
                )
            }
        }
    }
}
