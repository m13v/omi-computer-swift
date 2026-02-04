import SwiftUI

/// Shared store for all tasks - single source of truth
/// Both Dashboard and Tasks tab observe this store
@MainActor
class TasksStore: ObservableObject {
    static let shared = TasksStore()

    // MARK: - Published State

    @Published var tasks: [TaskActionItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMoreTasks = true
    @Published var error: String?

    // MARK: - Private State

    private var currentOffset = 0
    private let pageSize = 1000
    private var hasLoadedInitially = false

    // MARK: - Computed Properties (for Dashboard)

    /// 7-day cutoff for filtering old tasks (matches Flutter behavior)
    private var sevenDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    }

    var incompleteTasks: [TaskActionItem] {
        tasks.filter { !$0.completed }
    }

    var completedTasks: [TaskActionItem] {
        tasks.filter { $0.completed }
    }

    /// Overdue tasks (due date in the past but within 7 days)
    var overdueTasks: [TaskActionItem] {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return incompleteTasks
            .filter { task in
                guard let dueAt = task.dueAt else { return false }
                // Must be overdue (before today) but within 7 days (not too old)
                return dueAt < startOfToday && dueAt >= sevenDaysAgo
            }
            .sorted { a, b in
                // Sort by due date ascending, tie-breaker: created_at descending (matches backend)
                if a.dueAt == b.dueAt {
                    return a.createdAt > b.createdAt
                }
                return (a.dueAt ?? .distantPast) < (b.dueAt ?? .distantPast)
            }
    }

    /// Today's tasks (due today)
    var todaysTasks: [TaskActionItem] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        return incompleteTasks
            .filter { task in
                guard let dueAt = task.dueAt else { return false }
                return dueAt >= startOfToday && dueAt < endOfToday
            }
            .sorted { a, b in
                // Sort by due date ascending, tie-breaker: created_at descending (matches backend)
                if a.dueAt == b.dueAt {
                    return a.createdAt > b.createdAt
                }
                return (a.dueAt ?? .distantPast) < (b.dueAt ?? .distantPast)
            }
    }

    /// Tasks without due date (created within last 7 days)
    var tasksWithoutDueDate: [TaskActionItem] {
        incompleteTasks
            .filter { task in
                // No due date, but created within 7 days
                task.dueAt == nil && task.createdAt >= sevenDaysAgo
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var todoCount: Int {
        incompleteTasks.count
    }

    var doneCount: Int {
        completedTasks.count
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Load Tasks

    /// Load all tasks (call this once on app launch or when needed)
    func loadTasksIfNeeded() async {
        guard !hasLoadedInitially else { return }
        await loadTasks()
    }

    /// Force reload all tasks
    func loadTasks() async {
        // Prevent concurrent loads
        guard !isLoading else { return }

        isLoading = true
        error = nil
        currentOffset = 0

        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0
            )
            tasks = response.items
            hasMoreTasks = response.hasMore
            currentOffset = response.items.count
            hasLoadedInitially = true
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to load tasks", error: error)
        }

        isLoading = false
    }

    /// Load more tasks (pagination)
    func loadMoreIfNeeded(currentTask: TaskActionItem) async {
        guard hasMoreTasks, !isLoadingMore else { return }

        let thresholdIndex = tasks.index(tasks.endIndex, offsetBy: -10, limitedBy: tasks.startIndex) ?? tasks.startIndex
        guard let taskIndex = tasks.firstIndex(where: { $0.id == currentTask.id }),
              taskIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true

        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: currentOffset
            )
            tasks.append(contentsOf: response.items)
            hasMoreTasks = response.hasMore
            currentOffset += response.items.count
        } catch {
            logError("TasksStore: Failed to load more tasks", error: error)
        }

        isLoadingMore = false
    }

    // MARK: - Task Actions

    func toggleTask(_ task: TaskActionItem) async {
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                completed: !task.completed
            )
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updated
            }
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to toggle task", error: error)
        }
    }

    func createTask(description: String, dueAt: Date?, priority: String?) async {
        do {
            let created = try await APIClient.shared.createActionItem(
                description: description,
                dueAt: dueAt,
                source: "manual",
                priority: priority
            )
            tasks.insert(created, at: 0)
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to create task", error: error)
        }
    }

    func deleteTask(_ task: TaskActionItem) async {
        do {
            try await APIClient.shared.deleteActionItem(id: task.id)
            tasks.removeAll { $0.id == task.id }
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to delete task", error: error)
        }
    }

    func updateTask(_ task: TaskActionItem, description: String?, dueAt: Date?) async {
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                description: description,
                dueAt: dueAt
            )
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = updated
            }
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to update task", error: error)
        }
    }

    // MARK: - Bulk Actions

    func deleteMultipleTasks(ids: [String]) async {
        for id in ids {
            do {
                try await APIClient.shared.deleteActionItem(id: id)
                tasks.removeAll { $0.id == id }
            } catch {
                logError("TasksStore: Failed to delete task \(id)", error: error)
            }
        }
    }
}
