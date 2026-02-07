import SwiftUI
import Combine

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
    /// Soft-deleted tasks (Removed by AI) - loaded on demand when viewing filter
    @Published var deletedTasks: [TaskActionItem] = []

    @Published var isLoadingIncomplete = false
    @Published var isLoadingCompleted = false
    @Published var isLoadingDeleted = false
    @Published var isLoadingMore = false
    @Published var hasMoreIncompleteTasks = true
    @Published var hasMoreCompletedTasks = true
    @Published var hasMoreDeletedTasks = true
    @Published var error: String?

    // Legacy compatibility - combines both lists
    var tasks: [TaskActionItem] {
        incompleteTasks + completedTasks
    }

    var isLoading: Bool {
        isLoadingIncomplete || isLoadingCompleted || isLoadingDeleted
    }

    // MARK: - Private State

    private var incompleteOffset = 0
    private var completedOffset = 0
    private var deletedOffset = 0
    private let pageSize = 100  // Reduced from 1000 for better performance
    private var hasLoadedIncomplete = false
    private var hasLoadedCompleted = false
    private var hasLoadedDeleted = false
    /// Whether we're currently showing all tasks (no date filter) or just recent
    private var isShowingAllIncompleteTasks = false
    private var cancellables = Set<AnyCancellable>()

    /// Whether the tasks page (or dashboard) is currently visible.
    /// Auto-refresh only runs when active to avoid unnecessary API calls.
    var isActive = false {
        didSet {
            if isActive && !oldValue && hasLoadedIncomplete {
                // Refresh immediately when becoming active
                Task { await refreshTasksIfNeeded() }
            }
        }
    }

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

    var deletedCount: Int {
        deletedTasks.count
    }

    // MARK: - Initialization

    private init() {
        // Auto-refresh tasks every 30 seconds
        Timer.publish(every: 30.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { await self?.refreshTasksIfNeeded() }
            }
            .store(in: &cancellables)
    }

    /// Refresh tasks if already loaded (for auto-refresh)
    /// Uses local-first pattern: sync API to cache, then reload from cache
    private func refreshTasksIfNeeded() async {
        // Skip if page is not visible
        guard isActive else { return }

        // Skip if currently loading
        guard !isLoadingIncomplete, !isLoadingCompleted, !isLoadingDeleted, !isLoadingMore else { return }

        // Only refresh if we've already loaded tasks
        guard hasLoadedIncomplete else { return }

        // Silently sync and reload incomplete tasks (local-first pattern)
        do {
            let startDate = isShowingAllIncompleteTasks ? nil : sevenDaysAgo
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                completed: false,
                startDate: startDate
            )

            // Sync API results to local cache
            try await ActionItemStorage.shared.syncTaskActionItems(response.items)

            // Reload from local cache to get merged data (local + synced)
            let mergedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: 0,
                completed: false,
                startDate: startDate
            )
            incompleteTasks = mergedTasks
            hasMoreIncompleteTasks = mergedTasks.count >= pageSize
            incompleteOffset = mergedTasks.count
            log("TasksStore: Auto-refresh showing \(mergedTasks.count) incomplete tasks (API had \(response.items.count))")
        } catch {
            // Silently ignore errors during auto-refresh
            logError("TasksStore: Auto-refresh failed", error: error)
        }

        // Also refresh completed if loaded
        if hasLoadedCompleted {
            do {
                let response = try await APIClient.shared.getActionItems(
                    limit: pageSize,
                    offset: 0,
                    completed: true
                )

                // Sync to cache
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)

                // Reload from cache
                let mergedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                    limit: pageSize,
                    offset: 0,
                    completed: true
                )
                completedTasks = mergedTasks
                hasMoreCompletedTasks = mergedTasks.count >= pageSize
                completedOffset = mergedTasks.count
            } catch {
                logError("TasksStore: Auto-refresh completed tasks failed", error: error)
            }
        }

        // Also refresh deleted if loaded
        if hasLoadedDeleted {
            do {
                let response = try await APIClient.shared.getActionItems(
                    limit: pageSize,
                    offset: 0,
                    deleted: true
                )

                // Sync to cache
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)

                // Reload from cache
                let mergedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                    limit: pageSize,
                    offset: 0,
                    includeDeleted: true
                )
                // Filter to only deleted
                deletedTasks = mergedTasks.filter { $0.deleted == true }
                hasMoreDeletedTasks = response.hasMore
                deletedOffset = deletedTasks.count
            } catch {
                logError("TasksStore: Auto-refresh deleted tasks failed", error: error)
            }
        }
    }

    // MARK: - Load Tasks

    /// Load incomplete tasks if not already loaded (call this on app launch)
    func loadTasksIfNeeded() async {
        guard !hasLoadedIncomplete else { return }
        await loadIncompleteTasks(showAll: false)
        // Also load deleted tasks in background so the filter count is ready
        if !hasLoadedDeleted {
            await loadDeletedTasks()
        }
    }

    /// Legacy method - loads incomplete tasks with recent filter
    func loadTasks() async {
        await loadIncompleteTasks(showAll: isShowingAllIncompleteTasks)
        // Also load deleted tasks so the "Removed by AI" filter count is ready
        if !hasLoadedDeleted {
            await loadDeletedTasks()
        }
        // Kick off one-time full sync in background (populates SQLite with all tasks)
        Task { await performFullSyncIfNeeded() }
    }

    /// Load incomplete tasks (To Do) using local-first pattern
    /// - Parameter showAll: If false, only loads tasks from last 7 days. If true, loads all incomplete tasks.
    func loadIncompleteTasks(showAll: Bool) async {
        guard !isLoadingIncomplete else { return }

        isLoadingIncomplete = true
        error = nil
        incompleteOffset = 0
        isShowingAllIncompleteTasks = showAll

        let startDate = showAll ? nil : sevenDaysAgo

        // Step 1: Load from local cache first for instant display
        do {
            let cachedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: 0,
                completed: false,
                startDate: startDate
            )
            if !cachedTasks.isEmpty {
                incompleteTasks = cachedTasks
                incompleteOffset = cachedTasks.count
                hasMoreIncompleteTasks = cachedTasks.count >= pageSize
                isLoadingIncomplete = false  // Show cached data immediately
                log("TasksStore: Loaded \(cachedTasks.count) incomplete tasks from local cache")
            }
        } catch {
            log("TasksStore: Local cache unavailable for incomplete tasks, falling back to API")
        }

        // Step 2: Fetch from API and sync to local cache
        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                completed: false,
                startDate: startDate
            )
            hasLoadedIncomplete = true
            log("TasksStore: Fetched \(response.items.count) incomplete tasks from API")

            // Step 3: Sync to cache, then reload from cache
            do {
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)

                let mergedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                    limit: pageSize,
                    offset: 0,
                    completed: false,
                    startDate: startDate
                )
                incompleteTasks = mergedTasks
                incompleteOffset = mergedTasks.count
                hasMoreIncompleteTasks = mergedTasks.count >= pageSize
                log("TasksStore: Showing \(mergedTasks.count) incomplete tasks from merged local cache")
            } catch {
                logError("TasksStore: Failed to sync/reload incomplete tasks from local cache", error: error)
                // Fall back to API data
                incompleteTasks = response.items
                incompleteOffset = response.items.count
                hasMoreIncompleteTasks = response.hasMore
            }
        } catch {
            if incompleteTasks.isEmpty {
                self.error = error.localizedDescription
            }
            logError("TasksStore: Failed to load incomplete tasks from API", error: error)
        }

        isLoadingIncomplete = false
        NotificationCenter.default.post(name: .tasksPageDidLoad, object: nil)
    }

    /// Load completed tasks (Done) - called when user views Done tab
    /// Uses local-first pattern
    func loadCompletedTasks() async {
        guard !isLoadingCompleted else { return }

        isLoadingCompleted = true
        error = nil
        completedOffset = 0

        // Step 1: Load from local cache first
        do {
            let cachedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: 0,
                completed: true
            )
            if !cachedTasks.isEmpty {
                completedTasks = cachedTasks
                completedOffset = cachedTasks.count
                hasMoreCompletedTasks = cachedTasks.count >= pageSize
                isLoadingCompleted = false
                log("TasksStore: Loaded \(cachedTasks.count) completed tasks from local cache")
            }
        } catch {
            log("TasksStore: Local cache unavailable for completed tasks")
        }

        // Step 2: Fetch from API and sync
        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                completed: true
            )
            hasLoadedCompleted = true
            log("TasksStore: Fetched \(response.items.count) completed tasks from API")

            // Step 3: Sync and reload from cache
            do {
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)

                let mergedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                    limit: pageSize,
                    offset: 0,
                    completed: true
                )
                completedTasks = mergedTasks
                completedOffset = mergedTasks.count
                hasMoreCompletedTasks = mergedTasks.count >= pageSize
                log("TasksStore: Showing \(mergedTasks.count) completed tasks from merged local cache")
            } catch {
                logError("TasksStore: Failed to sync/reload completed tasks", error: error)
                completedTasks = response.items
                completedOffset = response.items.count
                hasMoreCompletedTasks = response.hasMore
            }
        } catch {
            if completedTasks.isEmpty {
                self.error = error.localizedDescription
            }
            logError("TasksStore: Failed to load completed tasks from API", error: error)
        }

        isLoadingCompleted = false
        NotificationCenter.default.post(name: .tasksPageDidLoad, object: nil)
    }

    /// Load deleted tasks (Removed by AI) - called when user views the filter
    /// Uses local-first pattern
    func loadDeletedTasks() async {
        guard !isLoadingDeleted else { return }

        isLoadingDeleted = true
        error = nil
        deletedOffset = 0

        // Step 1: Load from local cache first
        do {
            let cachedTasks = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: 0,
                completed: nil,
                includeDeleted: true
            )
            let deleted = cachedTasks.filter { $0.deleted == true }
            if !deleted.isEmpty {
                deletedTasks = deleted
                deletedOffset = deleted.count
                hasMoreDeletedTasks = deleted.count >= pageSize
                isLoadingDeleted = false
                log("TasksStore: Loaded \(deleted.count) deleted tasks from local cache")
            }
        } catch {
            log("TasksStore: Local cache unavailable for deleted tasks")
        }

        // Step 2: Fetch from API and sync
        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: 0,
                deleted: true
            )
            hasLoadedDeleted = true
            log("TasksStore: Fetched \(response.items.count) deleted tasks from API")

            // Step 3: Sync and reload from cache
            do {
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)

                let allTasks = try await ActionItemStorage.shared.getLocalActionItems(
                    limit: pageSize,
                    offset: 0,
                    completed: nil,
                    includeDeleted: true
                )
                let mergedDeleted = allTasks.filter { $0.deleted == true }
                deletedTasks = mergedDeleted
                deletedOffset = mergedDeleted.count
                hasMoreDeletedTasks = response.hasMore
                log("TasksStore: Showing \(mergedDeleted.count) deleted tasks from merged local cache")
            } catch {
                logError("TasksStore: Failed to sync/reload deleted tasks", error: error)
                deletedTasks = response.items
                deletedOffset = response.items.count
                hasMoreDeletedTasks = response.hasMore
            }
        } catch {
            if deletedTasks.isEmpty {
                self.error = error.localizedDescription
            }
            logError("TasksStore: Failed to load deleted tasks from API", error: error)
        }

        isLoadingDeleted = false
        NotificationCenter.default.post(name: .tasksPageDidLoad, object: nil)
    }

    /// One-time background sync that fetches ALL tasks from the API and stores in SQLite.
    /// Ensures filter/search queries have the full dataset. Keyed per user so it runs once per account.
    private func performFullSyncIfNeeded() async {
        let userId = UserDefaults.standard.string(forKey: "auth_userId") ?? "unknown"
        let syncKey = "tasksFullSyncCompleted_\(userId)"

        guard !UserDefaults.standard.bool(forKey: syncKey) else {
            log("TasksStore: Full sync already completed for user \(userId)")
            return
        }

        log("TasksStore: Starting one-time full sync for user \(userId)")

        var totalSynced = 0
        let batchSize = 500

        do {
            // Sync all incomplete tasks
            var offset = pageSize  // Skip first page (already synced)
            while true {
                let response = try await APIClient.shared.getActionItems(
                    limit: batchSize,
                    offset: offset,
                    completed: false
                )
                if response.items.isEmpty { break }
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)
                totalSynced += response.items.count
                offset += response.items.count
                log("TasksStore: Full sync progress - \(totalSynced) additional tasks synced (incomplete)")
                if !response.hasMore { break }
            }

            // Sync all completed tasks
            offset = pageSize
            while true {
                let response = try await APIClient.shared.getActionItems(
                    limit: batchSize,
                    offset: offset,
                    completed: true
                )
                if response.items.isEmpty { break }
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)
                totalSynced += response.items.count
                offset += response.items.count
                log("TasksStore: Full sync progress - \(totalSynced) additional tasks synced (completed)")
                if !response.hasMore { break }
            }

            // Sync all deleted tasks
            offset = pageSize
            while true {
                let response = try await APIClient.shared.getActionItems(
                    limit: batchSize,
                    offset: offset,
                    deleted: true
                )
                if response.items.isEmpty { break }
                try await ActionItemStorage.shared.syncTaskActionItems(response.items)
                totalSynced += response.items.count
                offset += response.items.count
                log("TasksStore: Full sync progress - \(totalSynced) additional tasks synced (deleted)")
                if !response.hasMore { break }
            }

            UserDefaults.standard.set(true, forKey: syncKey)
            log("TasksStore: Full sync completed - \(totalSynced) additional tasks synced total")
        } catch {
            logError("TasksStore: Full sync failed (will retry next launch)", error: error)
        }
    }

    /// Load more incomplete tasks (pagination) - local-first
    func loadMoreIncompleteIfNeeded(currentTask: TaskActionItem) async {
        guard hasMoreIncompleteTasks, !isLoadingMore else { return }

        let thresholdIndex = incompleteTasks.index(incompleteTasks.endIndex, offsetBy: -10, limitedBy: incompleteTasks.startIndex) ?? incompleteTasks.startIndex
        guard let taskIndex = incompleteTasks.firstIndex(where: { $0.id == currentTask.id }),
              taskIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true
        let startDate = isShowingAllIncompleteTasks ? nil : sevenDaysAgo

        // Step 1: Try to load more from local cache first
        do {
            let moreFromCache = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: incompleteOffset,
                completed: false,
                startDate: startDate
            )

            if !moreFromCache.isEmpty {
                incompleteTasks.append(contentsOf: moreFromCache)
                incompleteOffset += moreFromCache.count
                hasMoreIncompleteTasks = moreFromCache.count >= pageSize
                log("TasksStore: Loaded \(moreFromCache.count) more incomplete tasks from local cache")
                isLoadingMore = false
                return
            }
        } catch {
            log("TasksStore: Local cache pagination failed for incomplete tasks")
        }

        // Step 2: If local cache exhausted, fetch from API
        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: incompleteOffset,
                completed: false,
                startDate: startDate
            )

            // Sync to cache first
            try await ActionItemStorage.shared.syncTaskActionItems(response.items)

            incompleteTasks.append(contentsOf: response.items)
            hasMoreIncompleteTasks = response.hasMore
            incompleteOffset += response.items.count
            log("TasksStore: Loaded \(response.items.count) more incomplete tasks from API")
        } catch {
            logError("TasksStore: Failed to load more incomplete tasks", error: error)
        }

        isLoadingMore = false
    }

    /// Load more completed tasks (pagination) - local-first
    func loadMoreCompletedIfNeeded(currentTask: TaskActionItem) async {
        guard hasMoreCompletedTasks, !isLoadingMore else { return }

        let thresholdIndex = completedTasks.index(completedTasks.endIndex, offsetBy: -10, limitedBy: completedTasks.startIndex) ?? completedTasks.startIndex
        guard let taskIndex = completedTasks.firstIndex(where: { $0.id == currentTask.id }),
              taskIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true

        // Step 1: Try to load more from local cache first
        do {
            let moreFromCache = try await ActionItemStorage.shared.getLocalActionItems(
                limit: pageSize,
                offset: completedOffset,
                completed: true
            )

            if !moreFromCache.isEmpty {
                completedTasks.append(contentsOf: moreFromCache)
                completedOffset += moreFromCache.count
                hasMoreCompletedTasks = moreFromCache.count >= pageSize
                log("TasksStore: Loaded \(moreFromCache.count) more completed tasks from local cache")
                isLoadingMore = false
                return
            }
        } catch {
            log("TasksStore: Local cache pagination failed for completed tasks")
        }

        // Step 2: If local cache exhausted, fetch from API
        do {
            let response = try await APIClient.shared.getActionItems(
                limit: pageSize,
                offset: completedOffset,
                completed: true
            )

            // Sync to cache first
            try await ActionItemStorage.shared.syncTaskActionItems(response.items)

            completedTasks.append(contentsOf: response.items)
            hasMoreCompletedTasks = response.hasMore
            completedOffset += response.items.count
            log("TasksStore: Loaded \(response.items.count) more completed tasks from API")
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

    func createTask(description: String, dueAt: Date?, priority: String?, tags: [String]? = nil) async {
        do {
            var metadata: [String: Any]? = nil
            if let tags = tags, !tags.isEmpty {
                metadata = ["tags": tags]
            }

            let created = try await APIClient.shared.createActionItem(
                description: description,
                dueAt: dueAt,
                source: "manual",
                priority: priority,
                category: tags?.first,
                metadata: metadata
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

    func updateTask(_ task: TaskActionItem, description: String? = nil, dueAt: Date? = nil, priority: String? = nil) async {
        do {
            // Track manual edits: if description is changed, mark as manually edited
            var metadata: [String: Any]? = nil
            if description != nil {
                metadata = ["manually_edited": true]
                // Preserve existing tags in metadata
                if !task.tags.isEmpty {
                    metadata?["tags"] = task.tags
                }
            }

            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                description: description,
                dueAt: dueAt,
                priority: priority,
                metadata: metadata
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
