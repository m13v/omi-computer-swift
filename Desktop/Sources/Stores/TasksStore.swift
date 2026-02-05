import SwiftUI

/// Shared store for all tasks - single source of truth
/// Both Dashboard and Tasks tab observe this store
///
/// Tasks are loaded separately for incomplete vs completed to minimize memory usage.
/// By default, only recent (7 days) incomplete tasks are loaded.
@MainActor
class TasksStore: ObservableObject {
    static let shared = TasksStore()

    // MARK: - Published State

    /// Incomplete tasks (To Do) - loaded with 7-day filter by default
    @Published var incompleteTasks: [TaskActionItem] = []
    /// Completed tasks (Done) - loaded on demand when viewing Done tab
    @Published var completedTasks: [TaskActionItem] = []

    @Published var isLoadingIncomplete = false
    @Published var isLoadingCompleted = false
    @Published var isLoadingMore = false
    @Published var hasMoreIncompleteTasks = true
    @Published var hasMoreCompletedTasks = true
    @Published var error: String?

    // Legacy compatibility - combines both lists
    var tasks: [TaskActionItem] {
        incompleteTasks + completedTasks
    }

    var isLoading: Bool {
        isLoadingIncomplete || isLoadingCompleted
    }

    // MARK: - Private State

    private var incompleteOffset = 0
    private var completedOffset = 0
    private let pageSize = 100  // Reduced from 1000 for better performance
    private var hasLoadedIncomplete = false
    private var hasLoadedCompleted = false
    /// Whether we're currently showing all tasks (no date filter) or just recent
    private var isShowingAllIncompleteTasks = false

    // MARK: - Computed Properties (for Dashboard)

    /// 7-day cutoff for filtering old tasks (matches Flutter behavior)
    private var sevenDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
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

    /// Load incomplete tasks if not already loaded (call this on app launch)
    func loadTasksIfNeeded() async {
        guard !hasLoadedIncomplete else { return }
        await loadIncompleteTasks(showAll: false)
    }

    /// Legacy method - loads incomplete tasks with recent filter
    func loadTasks() async {
        await loadIncompleteTasks(showAll: isShowingAllIncompleteTasks)
    }

    /// Load incomplete tasks (To Do)
    /// - Parameter showAll: If false, only loads tasks from last 7 days. If true, loads all incomplete tasks.
    func loadIncompleteTasks(showAll: Bool) async {
        guard !isLoadingIncomplete else { return }

        isLoadingIncomplete = true
        error = nil
        incompleteOffset = 0
        isShowingAllIncompleteTasks = showAll

        do {
            // Only filter by date if not showing all tasks
            let startDate = showAll ? nil : sevenDaysAgo

            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                completed: false,
                startDate: startDate
            )
            incompleteTasks = response.items
            hasMoreIncompleteTasks = response.hasMore
            incompleteOffset = response.items.count
            hasLoadedIncomplete = true
            log("TasksStore: Loaded \(response.items.count) incomplete tasks (showAll: \(showAll))")
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to load incomplete tasks", error: error)
        }

        isLoadingIncomplete = false
    }

    /// Load completed tasks (Done) - called when user views Done tab
    func loadCompletedTasks() async {
        guard !isLoadingCompleted else { return }

        isLoadingCompleted = true
        error = nil
        completedOffset = 0

        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                completed: true
            )
            completedTasks = response.items
            hasMoreCompletedTasks = response.hasMore
            completedOffset = response.items.count
            hasLoadedCompleted = true
            log("TasksStore: Loaded \(response.items.count) completed tasks")
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to load completed tasks", error: error)
        }

        isLoadingCompleted = false
    }

    /// Load more incomplete tasks (pagination)
    func loadMoreIncompleteIfNeeded(currentTask: TaskActionItem) async {
        guard hasMoreIncompleteTasks, !isLoadingMore else { return }

        let thresholdIndex = incompleteTasks.index(incompleteTasks.endIndex, offsetBy: -10, limitedBy: incompleteTasks.startIndex) ?? incompleteTasks.startIndex
        guard let taskIndex = incompleteTasks.firstIndex(where: { $0.id == currentTask.id }),
              taskIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true

        do {
            let startDate = isShowingAllIncompleteTasks ? nil : sevenDaysAgo
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: incompleteOffset,
                completed: false,
                startDate: startDate
            )
            incompleteTasks.append(contentsOf: response.items)
            hasMoreIncompleteTasks = response.hasMore
            incompleteOffset += response.items.count
        } catch {
            logError("TasksStore: Failed to load more incomplete tasks", error: error)
        }

        isLoadingMore = false
    }

    /// Load more completed tasks (pagination)
    func loadMoreCompletedIfNeeded(currentTask: TaskActionItem) async {
        guard hasMoreCompletedTasks, !isLoadingMore else { return }

        let thresholdIndex = completedTasks.index(completedTasks.endIndex, offsetBy: -10, limitedBy: completedTasks.startIndex) ?? completedTasks.startIndex
        guard let taskIndex = completedTasks.firstIndex(where: { $0.id == currentTask.id }),
              taskIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true

        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: completedOffset,
                completed: true
            )
            completedTasks.append(contentsOf: response.items)
            hasMoreCompletedTasks = response.hasMore
            completedOffset += response.items.count
        } catch {
            logError("TasksStore: Failed to load more completed tasks", error: error)
        }

        isLoadingMore = false
    }

    /// Legacy pagination - routes to appropriate method based on task completion status
    func loadMoreIfNeeded(currentTask: TaskActionItem) async {
        if currentTask.completed {
            await loadMoreCompletedIfNeeded(currentTask: currentTask)
        } else {
            await loadMoreIncompleteIfNeeded(currentTask: currentTask)
        }
    }

    // MARK: - Task Actions

    func toggleTask(_ task: TaskActionItem) async {
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                completed: !task.completed
            )

            // Move task between lists based on new completion status
            if updated.completed {
                // Was incomplete, now completed - move to completed list
                incompleteTasks.removeAll { $0.id == task.id }
                completedTasks.insert(updated, at: 0)
            } else {
                // Was completed, now incomplete - move to incomplete list
                completedTasks.removeAll { $0.id == task.id }
                incompleteTasks.insert(updated, at: 0)
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
            // New tasks are incomplete, add to incomplete list
            incompleteTasks.insert(created, at: 0)
        } catch {
            self.error = error.localizedDescription
            logError("TasksStore: Failed to create task", error: error)
        }
    }

    func deleteTask(_ task: TaskActionItem) async {
        do {
            try await APIClient.shared.deleteActionItem(id: task.id)
            // Remove from appropriate list
            if task.completed {
                completedTasks.removeAll { $0.id == task.id }
            } else {
                incompleteTasks.removeAll { $0.id == task.id }
            }
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
            // Update in appropriate list
            if task.completed {
                if let index = completedTasks.firstIndex(where: { $0.id == task.id }) {
                    completedTasks[index] = updated
                }
            } else {
                if let index = incompleteTasks.firstIndex(where: { $0.id == task.id }) {
                    incompleteTasks[index] = updated
                }
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
                incompleteTasks.removeAll { $0.id == id }
                completedTasks.removeAll { $0.id == id }
            } catch {
                logError("TasksStore: Failed to delete task \(id)", error: error)
            }
        }
    }
}
