import SwiftUI

// MARK: - Task Classification Badge

/// Displays the classification category of a task (feature, bug, code, etc.)
struct TaskClassificationBadge: View {
    let category: String

    private var displayInfo: (label: String, icon: String, color: Color) {
        switch category.lowercased() {
        case "personal":
            return ("Personal", "person.fill", Color(hex: 0x8B5CF6))
        case "work":
            return ("Work", "briefcase.fill", Color(hex: 0x3B82F6))
        case "feature":
            return ("Feature", "sparkles", Color(hex: 0x10B981))
        case "bug":
            return ("Bug", "ladybug.fill", Color(hex: 0xEF4444))
        case "code":
            return ("Code", "chevron.left.forwardslash.chevron.right", Color(hex: 0xF59E0B))
        case "research":
            return ("Research", "magnifyingglass", Color(hex: 0x6366F1))
        case "communication":
            return ("Comms", "message.fill", Color(hex: 0xEC4899))
        case "finance":
            return ("Finance", "dollarsign.circle.fill", Color(hex: 0x14B8A6))
        case "health":
            return ("Health", "heart.fill", Color(hex: 0xF43F5E))
        default:
            return ("Other", "folder.fill", Color(hex: 0x6B7280))
        }
    }

    /// Check if this category triggers agent execution
    var triggersAgent: Bool {
        TaskAgentManager.agentCategories.contains(category.lowercased())
    }

    var body: some View {
        let info = displayInfo

        HStack(spacing: 3) {
            Image(systemName: info.icon)
                .font(.system(size: 8))

            Text(info.label)
                .font(.system(size: 10, weight: .medium))

            // Show terminal indicator for code-related categories
            if triggersAgent {
                Image(systemName: "terminal")
                    .font(.system(size: 7))
            }
        }
        .foregroundColor(info.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(info.color.opacity(0.15))
        )
    }
}

// MARK: - Agent Status Indicator

/// Shows the status of a Claude agent working on a task
struct AgentStatusIndicator: View {
    let taskId: String
    @ObservedObject private var manager = TaskAgentManager.shared

    private var session: TaskAgentManager.AgentSession? {
        manager.getSession(for: taskId)
    }

    var body: some View {
        if let session = session {
            Button {
                manager.openInTerminal(taskId: taskId)
            } label: {
                HStack(spacing: 4) {
                    statusIcon(for: session.status)

                    Text(session.status.displayName)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(statusColor(for: session.status))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(statusColor(for: session.status).opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .help("Click to open in Terminal")
        }
    }

    @ViewBuilder
    private func statusIcon(for status: TaskAgentManager.AgentStatus) -> some View {
        switch status {
        case .pending, .processing:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
        }
    }

    private func statusColor(for status: TaskAgentManager.AgentStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

// MARK: - Agent Launch Button

/// Button to launch a Claude agent for a task
struct AgentLaunchButton: View {
    let task: TaskActionItem
    @ObservedObject private var manager = TaskAgentManager.shared
    @ObservedObject private var settings = TaskAgentSettings.shared
    @State private var isLaunching = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var canLaunch: Bool {
        settings.isEnabled && !manager.hasSession(for: task.id)
    }

    var body: some View {
        if canLaunch {
            Button {
                launchAgent()
            } label: {
                HStack(spacing: 4) {
                    if isLaunching {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 10))
                    }

                    Text(isLaunching ? "Launching..." : "Run Agent")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.blue.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .disabled(isLaunching)
            .alert("Agent Error", isPresented: $showError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func launchAgent() {
        isLaunching = true

        Task {
            do {
                let context = TaskAgentContext()
                try await manager.launchAgent(for: task, context: context)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
            isLaunching = false
        }
    }
}

// MARK: - Task Agent Detail View

/// Detailed view showing agent status, prompt, and output for a task
struct TaskAgentDetailView: View {
    let task: TaskActionItem
    var onDismiss: (() -> Void)? = nil

    @ObservedObject private var manager = TaskAgentManager.shared
    @ObservedObject private var settings = TaskAgentSettings.shared
    @Environment(\.dismiss) private var environmentDismiss

    @State private var editedPrompt: String = ""
    @State private var isEditingPrompt = false
    @State private var isRestarting = false

    private var session: TaskAgentManager.AgentSession? {
        manager.getSession(for: task.id)
    }

    private func dismissSheet() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Task Info
                    taskInfoSection

                    // Agent Status
                    if let session = session {
                        agentStatusSection(session: session)
                    } else if settings.isEnabled {
                        launchSection
                    } else {
                        disabledSection
                    }

                    // Prompt Section
                    if let session = session {
                        promptSection(session: session)
                    }

                    // Output Section
                    if let session = session, let output = session.output, !output.isEmpty {
                        outputSection(output: output)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 550, height: 600)
        .background(OmiColors.backgroundPrimary)
        .onAppear {
            if let session = session {
                editedPrompt = session.prompt
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Task Agent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                if let category = task.category {
                    TaskClassificationBadge(category: category)
                }
            }

            Spacer()

            DismissButton(action: dismissSheet)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var taskInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Task")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)

            Text(task.description)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
        }
    }

    private func agentStatusSection(session: TaskAgentManager.AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)

            HStack(spacing: 16) {
                // Status badge
                HStack(spacing: 8) {
                    Image(systemName: session.status.icon)
                        .font(.system(size: 16))
                        .foregroundColor(statusColor(for: session.status))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.status.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Session: \(session.sessionName)")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 8) {
                    Button {
                        manager.openInTerminal(taskId: task.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11))
                            Text("Open Terminal")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.blue.opacity(0.1))
                        )
                    }
                    .buttonStyle(.plain)

                    if session.status == .processing || session.status == .pending {
                        Button {
                            manager.stopAgent(taskId: task.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11))
                                Text("Stop")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundColor(OmiColors.textTertiary)

                Text("No agent running")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textSecondary)

                Text("Launch a Claude agent to analyze this task and create an implementation plan.")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
                    .multilineTextAlignment(.center)

                AgentLaunchButton(task: task)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
    }

    private var disabledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent Status")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)

            VStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundColor(OmiColors.textTertiary)

                Text("Task Agent Disabled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textSecondary)

                Text("Enable Task Agent in settings to launch Claude agents for code-related tasks.")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
                    .multilineTextAlignment(.center)

                Button {
                    NotificationCenter.default.post(
                        name: .navigateToTaskSettings,
                        object: nil
                    )
                    dismissSheet()
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
    }

    private func promptSection(session: TaskAgentManager.AgentSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Prompt")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                if !isEditingPrompt {
                    Button {
                        editedPrompt = session.prompt
                        isEditingPrompt = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Edit")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isEditingPrompt {
                VStack(spacing: 8) {
                    TextEditor(text: $editedPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(OmiColors.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(OmiColors.border, lineWidth: 1)
                        )

                    HStack {
                        Button("Cancel") {
                            isEditingPrompt = false
                            editedPrompt = session.prompt
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            Task {
                                await restartWithNewPrompt()
                            }
                        } label: {
                            if isRestarting {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Restart Agent")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRestarting || editedPrompt.isEmpty)
                    }
                }
            } else {
                Text(session.prompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(OmiColors.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OmiColors.backgroundSecondary)
                    )
            }
        }
    }

    private func outputSection(output: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent Output")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(OmiColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.8))
            )
        }
    }

    private var footer: some View {
        HStack {
            if session != nil {
                Button("Remove Session") {
                    manager.removeSession(taskId: task.id)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }

            Spacer()

            Button("Close") {
                dismissSheet()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    // MARK: - Helpers

    private func statusColor(for status: TaskAgentManager.AgentStatus) -> Color {
        switch status {
        case .pending: return .orange
        case .processing: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }

    private func restartWithNewPrompt() async {
        isRestarting = true

        do {
            let context = TaskAgentContext()
            try await manager.updatePromptAndRestart(
                taskId: task.id,
                newPrompt: editedPrompt,
                context: context
            )
            isEditingPrompt = false
        } catch {
            // Handle error
        }

        isRestarting = false
    }
}


// MARK: - Preview

#Preview("Classification Badge") {
    VStack(spacing: 8) {
        ForEach(["feature", "bug", "code", "work", "personal", "research"], id: \.self) { category in
            TaskClassificationBadge(category: category)
        }
    }
    .padding()
}

#Preview("Agent Status") {
    VStack(spacing: 16) {
        AgentStatusIndicator(taskId: "test-1")
    }
    .padding()
}
