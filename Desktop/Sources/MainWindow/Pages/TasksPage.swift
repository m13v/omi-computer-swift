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
        switch filter {
        case .all:
            return tasks
        case .todo:
            return tasks.filter { !$0.completed }
        case .done:
            return tasks.filter { $0.completed }
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
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button(action: {
                Task {
                    await viewModel.toggleTask(task)
                }
            }) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(task.completed ? OmiColors.purplePrimary : OmiColors.textTertiary)
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
}
