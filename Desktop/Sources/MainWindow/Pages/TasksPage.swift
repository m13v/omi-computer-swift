import SwiftUI

// MARK: - Tasks View Model

@MainActor
class TasksViewModel: ObservableObject {
    @Published var tasks: [TaskActionItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var filter: TaskFilter = .all

    enum TaskFilter: String, CaseIterable {
        case all = "All"
        case todo = "To Do"
        case done = "Done"

        var completedFilter: Bool? {
            switch self {
            case .all: return nil
            case .todo: return false
            case .done: return true
            }
        }
    }

    var filteredTasks: [TaskActionItem] {
        let filtered: [TaskActionItem]
        switch filter {
        case .all:
            filtered = tasks
        case .todo:
            filtered = tasks.filter { !$0.completed }
        case .done:
            filtered = tasks.filter { $0.completed }
        }
        // Sort by: incomplete first, then high priority, then newest
        return filtered.sorted { a, b in
            // Incomplete tasks first
            if a.completed != b.completed {
                return !a.completed
            }
            // Then by priority (high > medium > low > nil)
            let priorityOrder = ["high": 0, "medium": 1, "low": 2]
            let aPriority = a.priority.flatMap { priorityOrder[$0] } ?? 3
            let bPriority = b.priority.flatMap { priorityOrder[$0] } ?? 3
            if aPriority != bPriority {
                return aPriority < bPriority
            }
            // Then by date (newest first)
            return a.createdAt > b.createdAt
        }
    }

    func loadTasks() async {
        isLoading = true
        error = nil

        do {
            tasks = try await APIClient.shared.getActionItems()
        } catch {
            self.error = error.localizedDescription
            logError("Failed to load tasks", error: error)
        }

        isLoading = false
    }

    func toggleTask(_ task: TaskActionItem) async {
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                completed: !task.completed
            )
            // Update local state
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updated
            }
        } catch {
            self.error = error.localizedDescription
            logError("Failed to toggle task", error: error)
        }
    }

    func deleteTask(_ task: TaskActionItem) async {
        do {
            try await APIClient.shared.deleteActionItem(id: task.id)
            // Remove from local state
            tasks.removeAll { $0.id == task.id }
        } catch {
            self.error = error.localizedDescription
            logError("Failed to delete task", error: error)
        }
    }
}

// MARK: - Tasks Page

struct TasksPage: View {
    @StateObject private var viewModel = TasksViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Filter tabs
            filterTabs

            // Content
            if viewModel.isLoading && viewModel.tasks.isEmpty {
                loadingView
            } else if let error = viewModel.error, viewModel.tasks.isEmpty {
                errorView(error)
            } else if viewModel.filteredTasks.isEmpty {
                emptyView
            } else {
                tasksList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .task {
            await viewModel.loadTasks()
        }
    }

    // MARK: - Filter Tabs

    private var filterTabs: some View {
        HStack(spacing: 4) {
            ForEach(TasksViewModel.TaskFilter.allCases, id: \.self) { filter in
                filterTab(filter)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func filterTab(_ filter: TasksViewModel.TaskFilter) -> some View {
        let isSelected = viewModel.filter == filter
        let count = countForFilter(filter)

        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.filter = filter
            }
        }) {
            HStack(spacing: 6) {
                Text(filter.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? OmiColors.textPrimary : OmiColors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? OmiColors.textPrimary.opacity(0.15) : OmiColors.textTertiary.opacity(0.1))
                        )
                }
            }
            .foregroundColor(isSelected ? OmiColors.textPrimary : OmiColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? OmiColors.backgroundTertiary : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func countForFilter(_ filter: TasksViewModel.TaskFilter) -> Int {
        switch filter {
        case .all:
            return viewModel.tasks.count
        case .todo:
            return viewModel.tasks.filter { !$0.completed }.count
        case .done:
            return viewModel.tasks.filter { $0.completed }.count
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(OmiColors.textSecondary)

            Text("Loading tasks...")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text("Failed to load tasks")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text(error)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Try Again") {
                Task {
                    await viewModel.loadTasks()
                }
            }
            .buttonStyle(.bordered)
            .tint(OmiColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: emptyViewIcon)
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text(emptyViewTitle)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text(emptyViewMessage)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)

            if viewModel.filter != .all && !viewModel.tasks.isEmpty {
                Button("View All Tasks") {
                    withAnimation {
                        viewModel.filter = .all
                    }
                }
                .buttonStyle(.bordered)
                .tint(OmiColors.textSecondary)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyViewIcon: String {
        switch viewModel.filter {
        case .all:
            return "checkmark.square.fill"
        case .todo:
            return "tray.fill"
        case .done:
            return "checkmark.circle.fill"
        }
    }

    private var emptyViewTitle: String {
        switch viewModel.filter {
        case .all:
            return "No Tasks"
        case .todo:
            return "All Caught Up!"
        case .done:
            return "No Completed Tasks"
        }
    }

    private var emptyViewMessage: String {
        switch viewModel.filter {
        case .all:
            return "Tasks from your conversations will appear here"
        case .todo:
            return "You have no pending tasks"
        case .done:
            return "Complete a task to see it here"
        }
    }

    // MARK: - Tasks List

    private var tasksList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredTasks) { task in
                    TaskRow(task: task, viewModel: viewModel)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .slide),
                            removal: .opacity.combined(with: .move(edge: .trailing))
                        ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.3), value: viewModel.filteredTasks.map(\.id))
        }
        .refreshable {
            await viewModel.loadTasks()
        }
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: TaskActionItem
    @ObservedObject var viewModel: TasksViewModel
    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var isCompletingAnimation = false
    @State private var checkmarkScale: CGFloat = 1.0
    @State private var rowOpacity: Double = 1.0
    @State private var rowOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox with animation
            Button(action: {
                handleToggle()
            }) {
                ZStack {
                    // Background circle
                    Circle()
                        .stroke(isCompletingAnimation || task.completed ? OmiColors.purplePrimary : OmiColors.textTertiary, lineWidth: 1.5)
                        .frame(width: 20, height: 20)

                    // Filled circle and checkmark
                    if isCompletingAnimation || task.completed {
                        Circle()
                            .fill(OmiColors.purplePrimary)
                            .frame(width: 20, height: 20)
                            .scaleEffect(checkmarkScale)

                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .scaleEffect(checkmarkScale)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            // Task content
            VStack(alignment: .leading, spacing: 4) {
                Text(task.description)
                    .font(.system(size: 14))
                    .foregroundColor(task.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                    .strikethrough(task.completed, color: OmiColors.textTertiary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    // Source badge
                    if let source = task.source {
                        SourceBadge(source: source, sourceLabel: task.sourceLabel, sourceIcon: task.sourceIcon)
                    }

                    // Priority badge
                    if let priority = task.priority, priority != "low" {
                        PriorityBadge(priority: priority)
                    }

                    // Created date
                    Text(task.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textTertiary)

                    // Due date if present
                    if let dueAt = task.dueAt {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 10))
                            Text("Due \(dueAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(dueAt < Date() && !task.completed ? .red : OmiColors.textTertiary)
                    }
                }
            }

            Spacer()

            // Delete button (visible on hover)
            if isHovering {
                Button(action: {
                    showDeleteConfirmation = true
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? OmiColors.backgroundTertiary : Color.clear)
        )
        .opacity(rowOpacity)
        .offset(x: rowOffset)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .confirmationDialog(
            "Delete Task",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteTask(task)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this task? This action cannot be undone.")
        }
    }

    private func handleToggle() {
        // If already completed, just toggle without animation
        if task.completed {
            Task {
                await viewModel.toggleTask(task)
            }
            return
        }

        // Animate the completion
        isCompletingAnimation = true

        // Checkmark pop animation
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            checkmarkScale = 1.2
        }

        // Scale back down
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                checkmarkScale = 1.0
            }
        }

        // Slide and fade out after a brief moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.3)) {
                rowOpacity = 0.0
                rowOffset = 50
            }
        }

        // Actually toggle the task after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            Task {
                await viewModel.toggleTask(task)
            }
        }
    }
}

// MARK: - Source Badge

struct SourceBadge: View {
    let source: String
    let sourceLabel: String
    let sourceIcon: String

    private var badgeColor: Color {
        switch source {
        case "screenshot":
            return .blue
        case "transcription:omi", "transcription:desktop", "transcription:phone":
            return .green
        case "manual":
            return .orange
        default:
            return OmiColors.textTertiary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: sourceIcon)
                .font(.system(size: 9))
            Text(sourceLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(badgeColor.opacity(0.15))
        )
    }
}

// MARK: - Priority Badge

struct PriorityBadge: View {
    let priority: String

    private var badgeColor: Color {
        switch priority {
        case "high":
            return .red
        case "medium":
            return .orange
        default:
            return OmiColors.textTertiary
        }
    }

    private var label: String {
        priority.capitalized
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(badgeColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(badgeColor.opacity(0.15))
            )
    }
}
