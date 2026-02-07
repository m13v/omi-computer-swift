import Foundation
import Combine

/// Manages Claude Code agent sessions for code-related tasks
class TaskAgentManager: ObservableObject {
    static let shared = TaskAgentManager()

    /// Categories that trigger agent execution
    static let agentCategories: Set<String> = ["feature", "bug", "code"]

    /// Active agent sessions: taskId -> session info
    @Published private(set) var activeSessions: [String: AgentSession] = [:]

    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    struct AgentSession: Identifiable {
        var id: String { taskId }
        let taskId: String
        let sessionName: String  // tmux session name
        var prompt: String
        var startedAt: Date
        var status: AgentStatus
        var output: String?
        var plan: String?
        var completedAt: Date?
    }

    enum AgentStatus: String, CaseIterable {
        case pending = "pending"
        case processing = "processing"
        case completed = "completed"
        case failed = "failed"

        var displayName: String {
            switch self {
            case .pending: return "Starting..."
            case .processing: return "Analyzing..."
            case .completed: return "Ready"
            case .failed: return "Failed"
            }
        }

        var icon: String {
            switch self {
            case .pending: return "clock"
            case .processing: return "bolt.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }
    }

    private init() {
        logMessage("TaskAgentManager: Initialized")
    }

    // MARK: - Public API

    /// Check if a task should trigger an agent
    func shouldTriggerAgent(for task: TaskActionItem) -> Bool {
        guard TaskAgentSettings.shared.isEnabled else { return false }
        guard let category = task.category else { return false }
        return Self.agentCategories.contains(category)
    }

    /// Check if a task has an active or completed agent session
    func hasSession(for taskId: String) -> Bool {
        return activeSessions[taskId] != nil
    }

    /// Get session for a task
    func getSession(for taskId: String) -> AgentSession? {
        return activeSessions[taskId]
    }

    /// Launch agent for a task
    func launchAgent(for task: TaskActionItem, context: TaskAgentContext) async throws {
        guard !hasSession(for: task.id) else {
            logMessage("TaskAgentManager: Session already exists for task \(task.id)")
            return
        }

        let sessionName = "omi-task-\(task.id.prefix(8))"
        let prompt = buildPrompt(for: task, context: context)

        logMessage("TaskAgentManager: Launching agent for task \(task.id) (\(task.description))")

        // Create session entry
        let session = AgentSession(
            taskId: task.id,
            sessionName: sessionName,
            prompt: prompt,
            startedAt: Date(),
            status: .pending,
            output: nil,
            plan: nil
        )

        await MainActor.run {
            activeSessions[task.id] = session
        }

        // Launch tmux session with Claude
        do {
            try await launchTmuxSession(sessionName: sessionName, prompt: prompt, workingDir: context.workingDirectory)

            await MainActor.run {
                activeSessions[task.id]?.status = .processing
            }

            // Start polling for completion
            startPolling(taskId: task.id, sessionName: sessionName)
        } catch {
            logMessage("TaskAgentManager: Failed to launch agent - \(error)")
            await MainActor.run {
                activeSessions[task.id]?.status = .failed
            }
            throw error
        }
    }

    /// Open session in Terminal
    func openInTerminal(taskId: String) {
        guard let session = activeSessions[taskId] else {
            logMessage("TaskAgentManager: No session found for task \(taskId)")
            return
        }
        logMessage("TaskAgentManager: Opening terminal for \(session.sessionName)")
        openTmuxSessionInTerminal(sessionName: session.sessionName)
    }

    /// Update prompt and restart agent
    func updatePromptAndRestart(taskId: String, newPrompt: String, context: TaskAgentContext) async throws {
        guard let session = activeSessions[taskId] else { return }
        let sessionName = session.sessionName

        logMessage("TaskAgentManager: Restarting agent for task \(taskId) with new prompt")

        // Cancel existing polling
        pollingTasks[taskId]?.cancel()
        pollingTasks[taskId] = nil

        // Kill existing session
        killTmuxSession(sessionName: sessionName)

        // Update session directly in activeSessions
        await MainActor.run {
            activeSessions[taskId]?.prompt = newPrompt
            activeSessions[taskId]?.startedAt = Date()
            activeSessions[taskId]?.status = .pending
            activeSessions[taskId]?.output = nil
            activeSessions[taskId]?.plan = nil
            activeSessions[taskId]?.completedAt = nil
        }

        try await launchTmuxSession(sessionName: sessionName, prompt: newPrompt, workingDir: context.workingDirectory)

        await MainActor.run {
            activeSessions[taskId]?.status = .processing
        }

        startPolling(taskId: taskId, sessionName: sessionName)
    }

    /// Stop and remove agent session
    func stopAgent(taskId: String) {
        guard let session = activeSessions[taskId] else { return }

        logMessage("TaskAgentManager: Stopping agent for task \(taskId)")

        // Cancel polling
        pollingTasks[taskId]?.cancel()
        pollingTasks[taskId] = nil

        // Kill tmux session
        killTmuxSession(sessionName: session.sessionName)

        // Remove from active sessions
        activeSessions.removeValue(forKey: taskId)
    }

    /// Remove completed session (cleanup)
    func removeSession(taskId: String) {
        pollingTasks[taskId]?.cancel()
        pollingTasks[taskId] = nil
        activeSessions.removeValue(forKey: taskId)
    }

    // MARK: - Private Implementation

    private func buildPrompt(for task: TaskActionItem, context: TaskAgentContext) -> String {
        var prompt = """
        # Task: \(task.description)

        Category: \(task.category ?? "unknown")
        Priority: \(task.priority ?? "medium")
        """

        if let sourceApp = task.sourceApp {
            prompt += "\nSource App: \(sourceApp)"
        }

        if let contextSummary = context.contextSummary {
            prompt += "\n\nContext from screen:\n\(contextSummary)"
        }

        // Add custom prefix if configured
        let customPrefix = TaskAgentSettings.shared.customPromptPrefix
        if !customPrefix.isEmpty {
            prompt += "\n\nAdditional context:\n\(customPrefix)"
        }

        prompt += """


        ## Instructions

        Analyze this task and create an implementation plan. Consider:
        1. What files need to be modified
        2. What is the approach
        3. Any potential issues or considerations
        4. Estimated complexity

        After creating the plan, wait for user approval before implementing.
        """

        return prompt
    }

    private func launchTmuxSession(sessionName: String, prompt: String, workingDir: String) async throws {
        // Check if tmux is available (source user's shell config to get full PATH)
        let tmuxCheck = Process()
        tmuxCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
        tmuxCheck.arguments = ["-c", "source ~/.zprofile 2>/dev/null; source ~/.zshrc 2>/dev/null; which tmux"]
        let tmuxCheckPipe = Pipe()
        tmuxCheck.standardOutput = tmuxCheckPipe
        tmuxCheck.standardError = tmuxCheckPipe

        try tmuxCheck.run()
        tmuxCheck.waitUntilExit()

        guard tmuxCheck.terminationStatus == 0 else {
            throw AgentError.tmuxNotInstalled
        }

        // Check if claude is available (source user's shell config to get full PATH)
        let claudeCheck = Process()
        claudeCheck.executableURL = URL(fileURLWithPath: "/bin/zsh")
        claudeCheck.arguments = ["-c", "source ~/.zprofile 2>/dev/null; source ~/.zshrc 2>/dev/null; which claude"]
        let claudeCheckPipe = Pipe()
        claudeCheck.standardOutput = claudeCheckPipe
        claudeCheck.standardError = claudeCheckPipe

        try claudeCheck.run()
        claudeCheck.waitUntilExit()

        guard claudeCheck.terminationStatus == 0 else {
            throw AgentError.claudeNotInstalled
        }

        // Write prompt to a temp file to avoid escaping issues
        let tempDir = FileManager.default.temporaryDirectory
        let promptFile = tempDir.appendingPathComponent("omi-task-prompt-\(UUID().uuidString).txt")
        try prompt.write(to: promptFile, atomically: true, encoding: .utf8)

        // Escape working directory for shell
        let escapedWorkingDir = workingDir.replacingOccurrences(of: "'", with: "'\\''")

        // Build command that reads prompt from file
        let command = """
        tmux new-session -d -s '\(sessionName)' "cd '\(escapedWorkingDir)' && claude --dangerously-skip-permissions \"$(cat '\(promptFile.path)')\" ; rm -f '\(promptFile.path)'"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "source ~/.zprofile 2>/dev/null; source ~/.zshrc 2>/dev/null; \(command)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            logMessage("TaskAgentManager: tmux launch failed - \(output)")
            throw AgentError.launchFailed(output)
        }

        logMessage("TaskAgentManager: Launched tmux session '\(sessionName)'")

        // Wait for Claude to initialize
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    }

    private func startPolling(taskId: String, sessionName: String) {
        // Cancel any existing polling for this task
        pollingTasks[taskId]?.cancel()

        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                guard self.activeSessions[taskId]?.status == .processing else { break }

                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

                guard !Task.isCancelled else { break }

                let output = self.readTmuxOutput(sessionName: sessionName)

                await MainActor.run {
                    self.activeSessions[taskId]?.output = output
                }

                // Check if session has completed (look for completion markers)
                if self.isSessionCompleted(output: output) {
                    await MainActor.run {
                        self.activeSessions[taskId]?.status = .completed
                        self.activeSessions[taskId]?.plan = self.extractPlan(from: output)
                        self.activeSessions[taskId]?.completedAt = Date()
                    }
                    logMessage("TaskAgentManager: Session completed for task \(taskId)")
                    break
                }

                // Check if session still exists
                if !self.isSessionAlive(sessionName: sessionName) {
                    await MainActor.run {
                        if self.activeSessions[taskId]?.status == .processing {
                            self.activeSessions[taskId]?.status = .failed
                        }
                    }
                    logMessage("TaskAgentManager: Session died for task \(taskId)")
                    break
                }
            }
        }

        pollingTasks[taskId] = task
    }

    private func readTmuxOutput(sessionName: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "source ~/.zprofile 2>/dev/null; tmux capture-pane -t '\(sessionName)' -p -S -500 2>/dev/null"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func isSessionAlive(sessionName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "source ~/.zprofile 2>/dev/null; tmux has-session -t '\(sessionName)' 2>/dev/null"]

        try? process.run()
        process.waitUntilExit()

        return process.terminationStatus == 0
    }

    private func isSessionCompleted(output: String) -> Bool {
        // Look for indicators that Claude has finished planning
        let completionMarkers = [
            "## Implementation Plan",
            "## Plan",
            "Ready to implement",
            "Waiting for approval",
            "Plan complete",
            "should I proceed",
            "Would you like me to",
            "Let me know if",
            "Do you want me to"
        ]

        for marker in completionMarkers {
            if output.lowercased().contains(marker.lowercased()) {
                return true
            }
        }

        return false
    }

    private func extractPlan(from output: String) -> String {
        // Extract the plan section from Claude's output
        // For now, return the full output - could be refined later
        return output
    }

    private func openTmuxSessionInTerminal(sessionName: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "tmux attach -t '\(sessionName)'"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        try? process.run()
    }

    private func killTmuxSession(sessionName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "source ~/.zprofile 2>/dev/null; tmux kill-session -t '\(sessionName)' 2>/dev/null"]

        try? process.run()
        process.waitUntilExit()
    }

    private func logMessage(_ message: String) {
        log(message)
    }

    // MARK: - Errors

    enum AgentError: LocalizedError {
        case tmuxNotInstalled
        case claudeNotInstalled
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .tmuxNotInstalled:
                return "tmux is not installed. Install with: brew install tmux"
            case .claudeNotInstalled:
                return "Claude CLI is not installed. Install from: https://claude.ai/claude-code"
            case .launchFailed(let output):
                return "Failed to launch agent: \(output)"
            }
        }
    }
}

/// Context for agent prompt building
struct TaskAgentContext {
    let workingDirectory: String
    let contextSummary: String?
    let recentScreenshots: [String]?  // Paths to recent screenshots
    let relatedConversation: String?  // Conversation transcript if available

    init(
        workingDirectory: String? = nil,
        contextSummary: String? = nil,
        recentScreenshots: [String]? = nil,
        relatedConversation: String? = nil
    ) {
        self.workingDirectory = workingDirectory ?? TaskAgentSettings.shared.workingDirectory
        self.contextSummary = contextSummary
        self.recentScreenshots = recentScreenshots
        self.relatedConversation = relatedConversation
    }
}
