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

    /// When true, show all tasks. When false, only show manual + top 5 AI tasks.
    @Published var showAllTasks = false

    /// Allowlist of AI task IDs that should be visible (top N by score).
    /// All manual tasks are always visible. AI tasks NOT in this set are hidden.
    /// Updated by TaskPrioritizationService.
    @Published var visibleAITaskIds: Set<String> = []

    /// Whether prioritization has completed at least once (used to avoid hiding before scoring)
    @Published var hasCompletedScoring = false

    /// Whether the prioritization service is currently scoring tasks
    @Published var isPrioritizing = false

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

    /// Source weight for priority sorting within the same day.
    /// Lower weight = higher priority. Manual tasks always appear above AI-generated.
    private static func sourceWeight(for source: String?) -> Int {
        switch source {
        case "manual": return 0
        case let s where s?.hasPrefix("transcription") == true: return 1
        case "screenshot": return 2
        default: return 1  // unknown sources treated as mid-priority
        }
    }

    /// Standard sort: due date ascending, then manual > AI-generated, then newest first
    private static func sortByDueDateThenSource(_ a: TaskActionItem, _ b: TaskActionItem) -> Bool {
        let aDue = a.dueAt ?? .distantFuture
        let bDue = b.dueAt ?? .distantFuture
        if aDue != bDue {
            return aDue < bDue
        }
        let aWeight = sourceWeight(for: a.source)
        let bWeight = sourceWeight(for: b.source)
        if aWeight != bWeight {
            return aWeight < bWeight
        }
        return a.createdAt > b.createdAt
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
            .sorted(by: Self.sortByDueDateThenSource)
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
            .sorted(by: Self.sortByDueDateThenSource)
    }

    /// Tasks without due date (created within last 7 days)
    var tasksWithoutDueDate: [TaskActionItem] {
        incompleteTasks
            .filter { task in
                // No due date, but created within 7 days
                task.dueAt == nil && task.createdAt >= sevenDaysAgo
            }
            .sorted(by: Self.sortByDueDateThenSource)
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

        // Listen for prioritization lifecycle
        NotificationCenter.default.publisher(for: .taskPrioritizationDidStart)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPrioritizing = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .taskPrioritizationDidUpdate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.refreshPrioritizationScores() }
            }
            .store(in: &cancellables)
    }

    /// Pull latest visible AI task IDs from the prioritization service
    private func refreshPrioritizationScores() async {
        let visible = await TaskPrioritizationService.shared.visibleAITaskIds
        let completed = await TaskPrioritizationService.shared.hasCompletedScoring
        let stillScoring = await TaskPrioritizationService.shared.isScoringInProgress
        if visible != visibleAITaskIds || completed != hasCompletedScoring {
            visibleAITaskIds = visible
            hasCompletedScoring = completed
            log("TasksStore: Updated from prioritization — \(visible.count) AI tasks visible, scoring completed: \(completed)")

            // Ensure allowlisted tasks are loaded (they may be older than the 7-day window)
            await ensureAllowlistedTasksLoaded(visible)
        }
        isPrioritizing = stillScoring
    }

    /// Fetch any allowlisted tasks missing from incompleteTasks (e.g. older than 7 days)
    private func ensureAllowlistedTasksLoaded(_ allowlist: Set<String>) async {
        let loadedIds = Set(incompleteTasks.map { $0.id })
        let missingIds = allowlist.subtracting(loadedIds)
        guard !missingIds.isEmpty else { return }

        do {
            // Fetch missing tasks from SQLite by their IDs
            var fetched: [TaskActionItem] = []
            for id in missingIds {
                if let task = try await ActionItemStorage.shared.getLocalActionItem(byBackendId: id) {
                    fetched.append(task)
                }
            }
            if !fetched.isEmpty {
                incompleteTasks.append(contentsOf: fetched)
                log("TasksStore: Loaded \(fetched.count) allowlisted tasks outside 7-day window")
            }
        } catch {
            log("TasksStore: Failed to load missing allowlisted tasks: \(error)")
        }
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
            if mergedTasks != incompleteTasks {
                incompleteTasks = mergedTasks
                hasMoreIncompleteTasks = mergedTasks.count >= pageSize
                incompleteOffset = mergedTasks.count
                log("TasksStore: Auto-refresh updated \(mergedTasks.count) incomplete tasks (API had \(response.items.count))")

                // Re-append allowlisted tasks that may be outside the loaded page
                if hasCompletedScoring && !visibleAITaskIds.isEmpty {
                    await ensureAllowlistedTasksLoaded(visibleAITaskIds)
                }
            }
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
                if mergedTasks != completedTasks {
                    completedTasks = mergedTasks
                    hasMoreCompletedTasks = mergedTasks.count >= pageSize
                    completedOffset = mergedTasks.count
                }
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
                let newDeleted = mergedTasks.filter { $0.deleted == true }
                if newDeleted != deletedTasks {
                    deletedTasks = newDeleted
                    hasMoreDeletedTasks = response.hasMore
                    deletedOffset = newDeleted.count
                }
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
        let syncKey = "tasksFullSyncCompleted_v3_\(userId)"

        guard !UserDefaults.standard.bool(forKey: syncKey) else {
            log("TasksStore: Full sync already completed for user \(userId)")
            return
        }

        log("TasksStore: Starting full sync for user \(userId)")

        var totalSynced = 0
        let batchSize = 500

        do {
            // Sync all incomplete tasks (start at 0 — initial load uses a date filter so it's a different dataset)
            var offset = 0
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
                log("TasksStore: Full sync progress - \(totalSynced) tasks synced (incomplete)")
                if response.items.count < batchSize { break }
            }

            // Sync all completed tasks
            offset = 0
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
                log("TasksStore: Full sync progress - \(totalSynced) tasks synced (completed)")
                if response.items.count < batchSize { break }
            }

            // Sync all deleted tasks
            offset = 0
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
                log("TasksStore: Full sync progress - \(totalSynced) tasks synced (deleted)")
                if response.items.count < batchSize { break }
            }

            UserDefaults.standard.set(true, forKey: syncKey)
            log("TasksStore: Full sync completed - \(totalSynced) tasks synced total")

            // Backfill due dates on backend for tasks that have none
            await backfillDueDatesOnBackendIfNeeded(userId: userId)
        } catch {
            logError("TasksStore: Full sync failed (will retry next launch)", error: error)
        }
    }

    /// One-time backfill: patch backend tasks that have no dueAt.
    /// Sets dueAt to end of the day the task was created.
    private func backfillDueDatesOnBackendIfNeeded(userId: String) async {
        let backfillKey = "tasksDueDateBackfill_v1_\(userId)"
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }

        log("TasksStore: Starting due date backfill for backend tasks")
        var patchedCount = 0

        do {
            // Fetch all incomplete tasks from local cache that have no dueAt
            let tasksWithoutDueDate = try await ActionItemStorage.shared.getLocalActionItems(
                limit: 500,
                completed: false
            ).filter { $0.dueAt == nil }

            for task in tasksWithoutDueDate {
                // Set dueAt to end of the day the task was created (11:59 PM local)
                let calendar = Calendar.current
                let endOfCreatedDay = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: task.createdAt)
                    ?? task.createdAt

                do {
                    _ = try await APIClient.shared.updateActionItem(
                        id: task.id,
                        dueAt: endOfCreatedDay
                    )
                    patchedCount += 1
                } catch {
                    logError("TasksStore: Failed to backfill dueAt for task \(task.id)", error: error)
                }
            }

            UserDefaults.standard.set(true, forKey: backfillKey)
            log("TasksStore: Due date backfill complete - patched \(patchedCount) tasks")
        } catch {
            logError("TasksStore: Due date backfill failed", error: error)
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
        // Local-first: soft-delete in SQLite immediately for instant UI update
        do {
            try await ActionItemStorage.shared.deleteActionItemByBackendId(task.id, deletedBy: "user")
        } catch {
            logError("TasksStore: Failed to soft-delete task locally", error: error)
        }

        // Remove from in-memory arrays immediately
        if task.completed {
            completedTasks.removeAll { $0.id == task.id }
        } else {
            incompleteTasks.removeAll { $0.id == task.id }
        }

        // Soft-delete on backend in background
        do {
            _ = try await APIClient.shared.softDeleteActionItem(id: task.id, deletedBy: "user")
        } catch {
            logError("TasksStore: Failed to soft-delete task on backend (local delete preserved)", error: error)
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
        // Local-first: soft-delete all in SQLite and remove from memory immediately
        for id in ids {
            do {
                try await ActionItemStorage.shared.deleteActionItemByBackendId(id, deletedBy: "user")
            } catch {
                logError("TasksStore: Failed to soft-delete task \(id) locally", error: error)
            }
            incompleteTasks.removeAll { $0.id == id }
            completedTasks.removeAll { $0.id == id }
        }

        // Soft-delete on backend in background
        for id in ids {
            do {
                _ = try await APIClient.shared.softDeleteActionItem(id: id, deletedBy: "user")
            } catch {
                logError("TasksStore: Failed to soft-delete task \(id) on backend (local delete preserved)", error: error)
            }
        }
    }
}
