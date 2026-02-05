import SwiftUI
import Combine

// MARK: - Task Category (by due date)

enum TaskCategory: String, CaseIterable {
    case today = "Today"
    case tomorrow = "Tomorrow"
    case later = "Later"
    case noDeadline = "No Deadline"

    var icon: String {
        switch self {
        case .today: return "sun.max.fill"
        case .tomorrow: return "sunrise.fill"
        case .later: return "calendar"
        case .noDeadline: return "tray.fill"
        }
    }

    var color: Color {
        switch self {
        case .today: return .yellow
        case .tomorrow: return .blue
        case .later: return OmiColors.purplePrimary
        case .noDeadline: return OmiColors.textTertiary
        }
    }
}

// MARK: - Sort Option

enum TaskSortOption: String, CaseIterable {
    case dueDate = "Due Date"
    case createdDate = "Created Date"
    case priority = "Priority"

    var icon: String {
        switch self {
        case .dueDate: return "calendar"
        case .createdDate: return "clock"
        case .priority: return "flag"
        }
    }
}

// MARK: - Tasks View Model (uses shared TasksStore)

@MainActor
class TasksViewModel: ObservableObject {
    // Use shared TasksStore as single source of truth
    private let store = TasksStore.shared

    // UI-specific state
    @Published var showCompleted = false {
        didSet { recomputeDisplayCaches() }
    }
    @Published var sortOption: TaskSortOption = .dueDate {
        didSet { recomputeDisplayCaches() }
    }
    /// When false (default), hides old incomplete tasks (>7 days) to match Flutter behavior
    @Published var showAllTasks = false {
        didSet { recomputeDisplayCaches() }
    }
    @Published var expandedCategories: Set<TaskCategory> = Set(TaskCategory.allCases)

    // Create/Edit task state
    @Published var showingCreateTask = false
    @Published var editingTask: TaskActionItem? = nil

    // Multi-select state
    @Published var isMultiSelectMode = false
    @Published var selectedTaskIds: Set<String> = []

    // MARK: - Drag-and-Drop Reordering (like Flutter)
    /// Custom order of task IDs per category (persisted to UserDefaults)
    @Published var categoryOrder: [TaskCategory: [String]] = [:] {
        didSet { saveCategoryOrder() }
    }

    // MARK: - Task Indentation (like Flutter)
    /// Indent levels for tasks (0-3), persisted to UserDefaults
    @Published var indentLevels: [String: Int] = [:] {
        didSet { saveIndentLevels() }
    }

    // Date filter state (filters locally from store's tasks)
    @Published var filterStartDate: Date? = nil {
        didSet { recomputeAllCaches() }
    }
    @Published var filterEndDate: Date? = nil {
        didSet { recomputeAllCaches() }
    }
    @Published var showingDateFilter = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Cached Properties (avoid recomputation on every render)

    @Published private(set) var displayTasks: [TaskActionItem] = []
    @Published private(set) var categorizedTasks: [TaskCategory: [TaskActionItem]] = [:]
    @Published private(set) var todoCount: Int = 0
    @Published private(set) var doneCount: Int = 0
    /// Count of old incomplete tasks hidden by the 7-day filter
    @Published private(set) var hiddenOldTasksCount: Int = 0

    // Delegate to store
    var isLoading: Bool { store.isLoading }
    var isLoadingMore: Bool { store.isLoadingMore }
    var hasMoreTasks: Bool { store.hasMoreTasks }
    var error: String? { store.error }
    var tasks: [TaskActionItem] { store.tasks }

    var isFiltered: Bool {
        filterStartDate != nil || filterEndDate != nil
    }

    init() {
        // Load saved order and indent levels
        loadCategoryOrder()
        loadIndentLevels()

        // Forward store changes to trigger view updates and recompute caches
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeAllCaches()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Persistence (UserDefaults)

    private static let categoryOrderKey = "TasksCategoryOrder"
    private static let indentLevelsKey = "TasksIndentLevels"

    private func loadCategoryOrder() {
        guard let data = UserDefaults.standard.dictionary(forKey: Self.categoryOrderKey) as? [String: [String]] else {
            return
        }
        var order: [TaskCategory: [String]] = [:]
        for (key, ids) in data {
            if let category = TaskCategory(rawValue: key) {
                order[category] = ids
            }
        }
        categoryOrder = order
    }

    private func saveCategoryOrder() {
        var data: [String: [String]] = [:]
        for (category, ids) in categoryOrder {
            data[category.rawValue] = ids
        }
        UserDefaults.standard.set(data, forKey: Self.categoryOrderKey)
    }

    private func loadIndentLevels() {
        guard let data = UserDefaults.standard.dictionary(forKey: Self.indentLevelsKey) as? [String: Int] else {
            return
        }
        indentLevels = data
    }

    private func saveIndentLevels() {
        UserDefaults.standard.set(indentLevels, forKey: Self.indentLevelsKey)
    }

    // MARK: - Drag-and-Drop Methods

    /// Get ordered tasks for a category, respecting custom order
    func getOrderedTasks(for category: TaskCategory) -> [TaskActionItem] {
        guard let tasks = categorizedTasks[category], !tasks.isEmpty else {
            return []
        }

        guard let order = categoryOrder[category], !order.isEmpty else {
            return tasks // No custom order, return as-is
        }

        // Sort tasks by custom order, new items go at the end
        var orderedTasks: [TaskActionItem] = []
        var taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        // Add tasks in custom order
        for id in order {
            if let task = taskMap[id] {
                orderedTasks.append(task)
                taskMap.removeValue(forKey: id)
            }
        }

        // Add remaining tasks (new ones not in custom order)
        orderedTasks.append(contentsOf: taskMap.values)

        return orderedTasks
    }

    /// Move a task within a category
    func moveTask(_ task: TaskActionItem, toIndex targetIndex: Int, inCategory category: TaskCategory) {
        var order = categoryOrder[category] ?? categorizedTasks[category]?.map { $0.id } ?? []

        // Remove task from current position
        order.removeAll { $0 == task.id }

        // Insert at new position
        let safeIndex = min(targetIndex, order.count)
        order.insert(task.id, at: safeIndex)

        categoryOrder[category] = order
    }

    /// Move a task to first position in category
    func moveTaskToFirst(_ task: TaskActionItem, inCategory category: TaskCategory) {
        moveTask(task, toIndex: 0, inCategory: category)
    }

    // MARK: - Indent Methods

    func getIndentLevel(for taskId: String) -> Int {
        return indentLevels[taskId] ?? 0
    }

    func incrementIndent(for taskId: String) {
        let current = indentLevels[taskId] ?? 0
        if current < 3 {
            indentLevels[taskId] = current + 1
        }
    }

    func decrementIndent(for taskId: String) {
        let current = indentLevels[taskId] ?? 0
        if current > 0 {
            indentLevels[taskId] = current - 1
        }
    }

    // MARK: - Cache Recomputation

    /// All tasks from store, optionally filtered by date
    private func computeFilteredTasks() -> [TaskActionItem] {
        var tasks = store.tasks

        // Apply local date filter if set
        if let start = filterStartDate {
            tasks = tasks.filter { $0.createdAt >= start }
        }
        if let end = filterEndDate {
            tasks = tasks.filter { $0.createdAt <= end }
        }

        return tasks
    }

    /// Recompute all caches when tasks or date filters change
    private func recomputeAllCaches() {
        let filtered = computeFilteredTasks()

        // Compute counts
        todoCount = filtered.filter { !$0.completed }.count
        doneCount = filtered.filter { $0.completed }.count

        // Recompute display caches
        recomputeDisplayCachesWithFiltered(filtered)
    }

    /// Recompute display-related caches when showCompleted or sortOption change
    private func recomputeDisplayCaches() {
        let filtered = computeFilteredTasks()
        recomputeDisplayCachesWithFiltered(filtered)
    }

    private func recomputeDisplayCachesWithFiltered(_ filtered: [TaskActionItem]) {
        // Compute displayTasks with optional 7-day age filter for incomplete tasks
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        let display: [TaskActionItem]
        if showCompleted {
            // Show all completed tasks (no age filter)
            display = filtered.filter { $0.completed }
            hiddenOldTasksCount = 0
        } else {
            // Show incomplete tasks, optionally filtered by age
            let allIncomplete = filtered.filter { !$0.completed }

            if showAllTasks {
                // Show all incomplete tasks
                display = allIncomplete
                hiddenOldTasksCount = 0
            } else {
                // Apply 7-day age filter (matching Flutter behavior):
                // Hide tasks that are > 7 days old AND don't have a future due date
                var visibleTasks: [TaskActionItem] = []
                var hiddenCount = 0

                for task in allIncomplete {
                    let isOldTask: Bool
                    if let dueAt = task.dueAt {
                        // Task has due date: hide if due date is > 7 days in the past
                        isOldTask = dueAt < sevenDaysAgo
                    } else {
                        // Task has no due date: hide if created > 7 days ago
                        isOldTask = task.createdAt < sevenDaysAgo
                    }

                    if isOldTask {
                        hiddenCount += 1
                    } else {
                        visibleTasks.append(task)
                    }
                }

                display = visibleTasks
                hiddenOldTasksCount = hiddenCount
            }
        }

        displayTasks = sortTasks(display)

        // Compute categorizedTasks
        var result: [TaskCategory: [TaskActionItem]] = [:]
        for category in TaskCategory.allCases {
            result[category] = []
        }
        for task in displayTasks {
            let category = categoryFor(task: task)
            result[category, default: []].append(task)
        }
        categorizedTasks = result
    }

    // MARK: - Category Helpers

    private func categoryFor(task: TaskActionItem) -> TaskCategory {
        guard let dueAt = task.dueAt else {
            return .noDeadline
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)!

        // Overdue and today's tasks go into "Today" category (like Flutter)
        if dueAt < startOfTomorrow {
            return .today
        } else if dueAt < startOfDayAfterTomorrow {
            return .tomorrow
        } else {
            return .later
        }
    }

    private func sortTasks(_ tasks: [TaskActionItem]) -> [TaskActionItem] {
        switch sortOption {
        case .dueDate:
            return tasks.sorted { a, b in
                // Tasks with due dates first, then by due date ascending
                // Tie-breaker: created_at descending (newest first) - matches backend
                switch (a.dueAt, b.dueAt) {
                case (nil, nil):
                    return a.createdAt > b.createdAt
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let aDate?, let bDate?):
                    if aDate == bDate {
                        // Tie-breaker: sort by created_at descending (newest first)
                        return a.createdAt > b.createdAt
                    }
                    return aDate < bDate
                }
            }
        case .createdDate:
            return tasks.sorted { $0.createdAt > $1.createdAt }
        case .priority:
            let priorityOrder = ["high": 0, "medium": 1, "low": 2]
            return tasks.sorted { a, b in
                let aPriority = a.priority.flatMap { priorityOrder[$0] } ?? 3
                let bPriority = b.priority.flatMap { priorityOrder[$0] } ?? 3
                if aPriority != bPriority {
                    return aPriority < bPriority
                }
                return a.createdAt > b.createdAt
            }
        }
    }

    // MARK: - Actions (delegate to shared store)

    func loadTasks() async {
        await store.loadTasks()
    }

    func loadMoreIfNeeded(currentTask: TaskActionItem) async {
        await store.loadMoreIfNeeded(currentTask: currentTask)
    }

    func applyDateFilter(startDate: Date?, endDate: Date?) {
        filterStartDate = startDate
        filterEndDate = endDate
        showingDateFilter = false
        // No need to reload - filtering is done locally
    }

    func clearDateFilter() {
        filterStartDate = nil
        filterEndDate = nil
        showingDateFilter = false
    }

    func toggleTask(_ task: TaskActionItem) async {
        log("TasksViewModel: toggleTask called for id=\(task.id)")
        await store.toggleTask(task)
    }

    func deleteTask(_ task: TaskActionItem) async {
        await store.deleteTask(task)
    }

    func toggleCategory(_ category: TaskCategory) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }

    // MARK: - Multi-Select

    func toggleMultiSelectMode() {
        isMultiSelectMode.toggle()
        if !isMultiSelectMode {
            selectedTaskIds.removeAll()
        }
    }

    func toggleTaskSelection(_ task: TaskActionItem) {
        if selectedTaskIds.contains(task.id) {
            selectedTaskIds.remove(task.id)
        } else {
            selectedTaskIds.insert(task.id)
        }
    }

    func selectAll() {
        selectedTaskIds = Set(displayTasks.map { $0.id })
    }

    func deselectAll() {
        selectedTaskIds.removeAll()
    }

    func deleteSelectedTasks() async {
        let idsToDelete = Array(selectedTaskIds)
        await store.deleteMultipleTasks(ids: idsToDelete)
        selectedTaskIds.removeAll()
        isMultiSelectMode = false
    }

    func createTask(description: String, dueAt: Date?, priority: String?) async {
        await store.createTask(description: description, dueAt: dueAt, priority: priority)
        showingCreateTask = false
    }

    func updateTaskDetails(_ task: TaskActionItem, description: String?, dueAt: Date?, priority: String?) async {
        await store.updateTask(task, description: description, dueAt: dueAt)
        editingTask = nil
    }
}

// MARK: - Tasks Page

struct TasksPage: View {
    @ObservedObject var viewModel: TasksViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with filter toggle and sort
            headerView

            // Content
            if viewModel.isLoading && viewModel.tasks.isEmpty {
                loadingView
            } else if let error = viewModel.error, viewModel.tasks.isEmpty {
                errorView(error)
            } else if viewModel.displayTasks.isEmpty {
                emptyView
            } else {
                tasksListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .dismissableSheet(isPresented: $viewModel.showingCreateTask) {
            TaskEditSheet(
                mode: .create,
                viewModel: viewModel,
                onDismiss: { viewModel.showingCreateTask = false }
            )
        }
        .dismissableSheet(item: $viewModel.editingTask) { task in
            TaskEditSheet(
                mode: .edit(task),
                viewModel: viewModel,
                onDismiss: { viewModel.editingTask = nil }
            )
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            // To Do / Done toggle
            if !viewModel.isMultiSelectMode {
                filterToggle
            } else {
                // Multi-select controls
                multiSelectControls
            }

            Spacer()

            if viewModel.isMultiSelectMode {
                // Delete selected button
                if !viewModel.selectedTaskIds.isEmpty {
                    deleteSelectedButton
                }
            } else {
                // Add Task button
                addTaskButton
            }

            // Multi-select toggle / Filter / Sort dropdown
            if viewModel.isMultiSelectMode {
                cancelMultiSelectButton
            } else {
                // Show "Show All" toggle only when viewing To Do (incomplete) tasks
                if !viewModel.showCompleted {
                    showAllTasksToggle
                }
                dateFilterButton
                multiSelectToggleButton
                sortDropdown
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var dateFilterButton: some View {
        Button {
            viewModel.showingDateFilter.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                if viewModel.isFiltered {
                    Text("Filtered")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(viewModel.isFiltered ? OmiColors.purplePrimary : OmiColors.textSecondary)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.isFiltered ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundSecondary)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $viewModel.showingDateFilter) {
            DateFilterPopover(viewModel: viewModel)
        }
    }

    private var showAllTasksToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                viewModel.showAllTasks.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.showAllTasks ? "eye.fill" : "eye.slash")
                    .font(.system(size: 12))
                if viewModel.showAllTasks {
                    Text("All")
                        .font(.system(size: 11, weight: .medium))
                } else if viewModel.hiddenOldTasksCount > 0 {
                    Text("+\(viewModel.hiddenOldTasksCount)")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(viewModel.showAllTasks ? OmiColors.purplePrimary : OmiColors.textSecondary)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.showAllTasks ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundSecondary)
            )
        }
        .buttonStyle(.plain)
        .help(viewModel.showAllTasks ? "Showing all tasks" : "Showing recent tasks (7 days). \(viewModel.hiddenOldTasksCount) older tasks hidden.")
    }

    private var multiSelectControls: some View {
        HStack(spacing: 12) {
            Button {
                if viewModel.selectedTaskIds.count == viewModel.displayTasks.count {
                    viewModel.deselectAll()
                } else {
                    viewModel.selectAll()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: viewModel.selectedTaskIds.count == viewModel.displayTasks.count ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                    Text(viewModel.selectedTaskIds.count == viewModel.displayTasks.count ? "Deselect All" : "Select All")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(OmiColors.textSecondary)
            }
            .buttonStyle(.plain)

            Text("\(viewModel.selectedTaskIds.count) selected")
                .font(.system(size: 13))
                .foregroundColor(OmiColors.textTertiary)
        }
    }

    private var deleteSelectedButton: some View {
        Button {
            Task {
                await viewModel.deleteSelectedTasks()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                Text("Delete \(viewModel.selectedTaskIds.count)")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red)
            )
        }
        .buttonStyle(.plain)
    }

    private var multiSelectToggleButton: some View {
        Button {
            viewModel.toggleMultiSelectMode()
        } label: {
            Image(systemName: "checklist")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textSecondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
        }
        .buttonStyle(.plain)
        .help("Select multiple tasks")
    }

    private var cancelMultiSelectButton: some View {
        Button {
            viewModel.toggleMultiSelectMode()
        } label: {
            Text("Cancel")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
        }
        .buttonStyle(.plain)
    }

    private var addTaskButton: some View {
        Button {
            viewModel.showingCreateTask = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add Task")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OmiColors.purplePrimary)
            )
        }
        .buttonStyle(.plain)
    }

    private var filterToggle: some View {
        HStack(spacing: 2) {
            filterButton(title: "To Do", count: viewModel.todoCount, isSelected: !viewModel.showCompleted) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showCompleted = false
                }
            }

            filterButton(title: "Done", count: viewModel.doneCount, isSelected: viewModel.showCompleted) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showCompleted = true
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundSecondary)
        )
    }

    private func filterButton(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
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

    private var sortDropdown: some View {
        Menu {
            ForEach(TaskSortOption.allCases, id: \.self) { option in
                Button(action: {
                    withAnimation {
                        viewModel.sortOption = option
                    }
                }) {
                    HStack {
                        Image(systemName: option.icon)
                        Text(option.rawValue)
                        if viewModel.sortOption == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                Text(viewModel.sortOption.rawValue)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(OmiColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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

            if viewModel.showCompleted && viewModel.todoCount > 0 {
                Button("View To Do") {
                    withAnimation {
                        viewModel.showCompleted = false
                    }
                }
                .buttonStyle(.bordered)
                .tint(OmiColors.textSecondary)
                .padding(.top, 8)
            } else if !viewModel.showCompleted && viewModel.hiddenOldTasksCount > 0 {
                // Show option to view hidden old tasks
                Button("Show \(viewModel.hiddenOldTasksCount) Older Tasks") {
                    withAnimation {
                        viewModel.showAllTasks = true
                    }
                }
                .buttonStyle(.bordered)
                .tint(OmiColors.textSecondary)
                .padding(.top, 8)
            } else if !viewModel.showCompleted && viewModel.doneCount > 0 {
                Button("View Done") {
                    withAnimation {
                        viewModel.showCompleted = true
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
        viewModel.showCompleted ? "checkmark.circle.fill" : "tray.fill"
    }

    private var emptyViewTitle: String {
        viewModel.showCompleted ? "No Completed Tasks" : "All Caught Up!"
    }

    private var emptyViewMessage: String {
        if viewModel.tasks.isEmpty {
            return "Tasks from your conversations will appear here"
        }
        if viewModel.showCompleted {
            return "Complete a task to see it here"
        }
        if viewModel.hiddenOldTasksCount > 0 {
            return "No recent tasks. You have \(viewModel.hiddenOldTasksCount) older tasks hidden."
        }
        return "You have no pending tasks"
    }

    // MARK: - Tasks List View

    private var tasksListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Show tasks grouped by category when sorting by due date
                if viewModel.sortOption == .dueDate && !viewModel.showCompleted && !viewModel.isMultiSelectMode {
                    ForEach(TaskCategory.allCases, id: \.self) { category in
                        let tasksInCategory = viewModel.categorizedTasks[category] ?? []
                        if !tasksInCategory.isEmpty {
                            TaskCategorySection(
                                category: category,
                                tasks: tasksInCategory,
                                isExpanded: viewModel.expandedCategories.contains(category),
                                onToggle: { viewModel.toggleCategory(category) },
                                viewModel: viewModel
                            )
                        }
                    }
                } else {
                    // Flat list for other sort options, completed view, or multi-select mode
                    ForEach(viewModel.displayTasks) { task in
                        TaskRow(task: task, viewModel: viewModel)
                            .onAppear {
                                Task {
                                    await viewModel.loadMoreIfNeeded(currentTask: task)
                                }
                            }
                    }
                }

                // Loading more indicator
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 12)
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

// MARK: - Task Category Section

struct TaskCategorySection: View {
    let category: TaskCategory
    let tasks: [TaskActionItem]
    let isExpanded: Bool
    let onToggle: () -> Void
    @ObservedObject var viewModel: TasksViewModel

    /// Get ordered tasks respecting custom drag order
    private var orderedTasks: [TaskActionItem] {
        viewModel.getOrderedTasks(for: category)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Category header
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: category.icon)
                        .font(.system(size: 14))
                        .foregroundColor(category.color)

                    Text(category.rawValue)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(OmiColors.textPrimary)

                    Text("\(tasks.count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(OmiColors.textTertiary.opacity(0.1))
                        )

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Tasks in category with drag-and-drop reordering
            if isExpanded && !viewModel.isMultiSelectMode {
                VStack(spacing: 8) {
                    ForEach(orderedTasks) { task in
                        TaskRow(task: task, viewModel: viewModel, category: category)
                            .draggable(task.id) {
                                // Drag preview
                                TaskDragPreview(task: task)
                            }
                            .dropDestination(for: String.self) { droppedIds, _ in
                                guard let droppedId = droppedIds.first,
                                      orderedTasks.contains(where: { $0.id == droppedId }),
                                      let targetIndex = orderedTasks.firstIndex(where: { $0.id == task.id }) else {
                                    return false
                                }
                                // Move the task
                                if let droppedTask = orderedTasks.first(where: { $0.id == droppedId }) {
                                    viewModel.moveTask(droppedTask, toIndex: targetIndex, inCategory: category)
                                }
                                return true
                            }
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)),
                                removal: .opacity.combined(with: .move(edge: .trailing))
                            ))
                    }
                }
            }
        }
    }
}

// MARK: - Task Drag Preview

struct TaskDragPreview: View {
    let task: TaskActionItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle")
                .font(.system(size: 16))
                .foregroundColor(OmiColors.textTertiary)

            Text(task.description)
                .font(.system(size: 13))
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(OmiColors.backgroundSecondary)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        )
        .frame(maxWidth: 300)
    }
}

// MARK: - Task Row

struct TaskRow: View {
    let task: TaskActionItem
    @ObservedObject var viewModel: TasksViewModel
    var category: TaskCategory? = nil  // Optional for flat list views

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false
    @State private var isCompletingAnimation = false
    @State private var checkmarkScale: CGFloat = 1.0
    @State private var rowOpacity: Double = 1.0
    @State private var rowOffset: CGFloat = 0

    // Swipe gesture state
    @State private var swipeOffset: CGFloat = 0
    @State private var isDragging = false

    /// Threshold for triggering delete (30% of row width, like Flutter)
    private let deleteThreshold: CGFloat = 100
    /// Threshold for triggering indent change (25% of row width)
    private let indentThreshold: CGFloat = 80

    private var isSelected: Bool {
        viewModel.selectedTaskIds.contains(task.id)
    }

    /// Indent level for this task (0-3)
    private var indentLevel: Int {
        viewModel.getIndentLevel(for: task.id)
    }

    /// Indent amount in points (28pt per level, like Flutter)
    private var indentPadding: CGFloat {
        CGFloat(indentLevel) * 28
    }

    var body: some View {
        swipeableContent
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

    // MARK: - Swipeable Content

    private var swipeableContent: some View {
        ZStack(alignment: .trailing) {
            // Delete background (revealed when swiping left)
            if swipeOffset < 0 {
                deleteBackground
            }

            // Indent background (revealed when swiping right)
            if swipeOffset > 0 && indentLevel < 3 {
                indentBackground
            }

            // Main task row content
            taskRowContent
                .offset(x: swipeOffset)
                .gesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .local)
                        .onChanged { value in
                            guard !viewModel.isMultiSelectMode else { return }
                            isDragging = true

                            // Apply resistance at the edges
                            let translation = value.translation.width
                            if translation < 0 {
                                // Swiping left (delete)
                                swipeOffset = translation * 0.8
                            } else if translation > 0 && indentLevel < 3 {
                                // Swiping right (indent) - only if can indent more
                                swipeOffset = translation * 0.6
                            } else if translation > 0 && indentLevel > 0 {
                                // Swiping right when can outdent
                                swipeOffset = translation * 0.6
                            }
                        }
                        .onEnded { value in
                            isDragging = false
                            handleSwipeEnd(velocity: value.velocity.width)
                        }
                )
        }
        .clipped()
    }

    // MARK: - Swipe Backgrounds

    private var deleteBackground: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                if swipeOffset < -deleteThreshold {
                    Text("Release to delete")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red)
        .cornerRadius(8)
    }

    private var indentBackground: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.to.line")
                    .font(.system(size: 16, weight: .semibold))
                if swipeOffset > indentThreshold {
                    Text("Release to indent")
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OmiColors.purplePrimary)
        .cornerRadius(8)
    }

    /// Outdent background (revealed when swiping left on indented tasks)
    private var outdentBackground: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                if swipeOffset < -indentThreshold {
                    Text("Release to outdent")
                        .font(.system(size: 13, weight: .medium))
                }
                Image(systemName: "arrow.left.to.line")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.orange)
        .cornerRadius(8)
    }

    // MARK: - Swipe Handling

    private func handleSwipeEnd(velocity: CGFloat) {
        let shouldDelete = swipeOffset < -deleteThreshold || velocity < -500
        let shouldIndent = swipeOffset > indentThreshold || velocity > 500

        if shouldDelete {
            // Animate off screen and delete
            withAnimation(.easeOut(duration: 0.2)) {
                swipeOffset = -400
                rowOpacity = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                Task {
                    await viewModel.deleteTask(task)
                }
            }
        } else if shouldIndent && indentLevel < 3 {
            // Increment indent and snap back
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                swipeOffset = 0
            }
            viewModel.incrementIndent(for: task.id)
        } else {
            // Snap back to original position
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                swipeOffset = 0
            }
        }
    }

    private var taskRowContent: some View {
        HStack(alignment: .center, spacing: 12) {
            // Indent visual (vertical line for indented tasks)
            if indentLevel > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<indentLevel, id: \.self) { level in
                        Rectangle()
                            .fill(OmiColors.textQuaternary.opacity(0.5))
                            .frame(width: 2)
                            .padding(.leading, level == 0 ? 8 : 26)
                    }
                }
                .frame(width: indentPadding)
            }
            // Multi-select checkbox or completion checkbox
            if viewModel.isMultiSelectMode {
                Button {
                    viewModel.toggleTaskSelection(task)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? OmiColors.purplePrimary : OmiColors.textTertiary, lineWidth: 1.5)
                            .frame(width: 20, height: 20)

                        if isSelected {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(OmiColors.purplePrimary)
                                .frame(width: 20, height: 20)

                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                // Completion checkbox with animation
                Button {
                    log("Task: Checkbox clicked for task: \(task.id)")
                    handleToggle()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(isCompletingAnimation || task.completed ? OmiColors.purplePrimary : OmiColors.textTertiary, lineWidth: 1.5)
                            .frame(width: 20, height: 20)

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
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Task content (tappable for editing or selection)
            Button {
                if viewModel.isMultiSelectMode {
                    viewModel.toggleTaskSelection(task)
                } else {
                    viewModel.editingTask = task
                }
            } label: {
                // Inline layout: title followed by metadata badges, wrapping if needed
                FlowLayout(spacing: 6) {
                    Text(task.description)
                        .font(.system(size: 14))
                        .foregroundColor(task.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                        .strikethrough(task.completed, color: OmiColors.textTertiary)

                    // Due date badge (color-coded)
                    if let dueAt = task.dueAt {
                        DueDateBadgeCompact(dueAt: dueAt, isCompleted: task.completed)
                    }

                    // Source badge
                    if let source = task.source {
                        SourceBadgeCompact(source: source, sourceLabel: task.sourceLabel, sourceIcon: task.sourceIcon)
                    }

                    // Priority badge
                    if let priority = task.priority, priority != "low" {
                        PriorityBadgeCompact(priority: priority)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // Hover actions: indent controls and delete
            if isHovering && !viewModel.isMultiSelectMode {
                HStack(spacing: 4) {
                    // Outdent button (decrease indent)
                    if indentLevel > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.decrementIndent(for: task.id)
                            }
                        } label: {
                            Image(systemName: "arrow.left.to.line")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Decrease indent")
                    }

                    // Indent button (increase indent)
                    if indentLevel < 3 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.incrementIndent(for: task.id)
                            }
                        } label: {
                            Image(systemName: "arrow.right.to.line")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Increase indent")
                    }

                    // Delete button
                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textTertiary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, indentPadding > 0 ? 0 : 12)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering || isDragging ? OmiColors.backgroundTertiary : OmiColors.backgroundPrimary)
        )
        .opacity(rowOpacity)
        .offset(x: rowOffset)
        .onAppear {
            rowOpacity = 1.0
            rowOffset = 0
            isCompletingAnimation = false
            checkmarkScale = 1.0
        }
        .onChange(of: task.completed) { _, _ in
            rowOpacity = 1.0
            rowOffset = 0
            isCompletingAnimation = false
            checkmarkScale = 1.0
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func handleToggle() {
        log("Task: handleToggle called, completed=\(task.completed)")

        if task.completed {
            log("Task: Already completed, toggling back")
            Task {
                await viewModel.toggleTask(task)
            }
            return
        }

        log("Task: Starting completion animation")
        isCompletingAnimation = true

        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            checkmarkScale = 1.2
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                self.checkmarkScale = 1.0
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.rowOpacity = 0.0
                self.rowOffset = 50
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            log("Task: Animation complete, calling toggleTask")
            Task {
                await self.viewModel.toggleTask(self.task)
            }
        }
    }
}

// MARK: - Due Date Badge

struct DueDateBadge: View {
    let dueAt: Date
    let isCompleted: Bool

    private var badgeInfo: (text: String, color: Color) {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)!
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)!

        if isCompleted {
            return (dueAt.formatted(date: .abbreviated, time: .omitted), OmiColors.textTertiary)
        }

        if dueAt < startOfToday {
            // Show relative date for overdue tasks with subtle red (like Flutter)
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return (formatter.localizedString(for: dueAt, relativeTo: now), Color.red.opacity(0.8))
        } else if dueAt < startOfTomorrow {
            return ("Today", .yellow)
        } else if dueAt < startOfDayAfterTomorrow {
            return ("Tomorrow", .blue)
        } else if dueAt < endOfWeek {
            let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: dueAt) - 1]
            return (weekday, .green)
        } else {
            return (dueAt.formatted(date: .abbreviated, time: .omitted), OmiColors.purplePrimary)
        }
    }

    var body: some View {
        let info = badgeInfo
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10))
            Text("due: \(info.text)")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(info.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(info.color.opacity(0.15))
        )
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

// FlowLayout is defined in AppsPage.swift

// MARK: - Compact Badges (for inline display)

struct DueDateBadgeCompact: View {
    let dueAt: Date
    let isCompleted: Bool

    private var displayText: String {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
        let startOfDayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: startOfToday)!
        let endOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)!

        if isCompleted {
            return dueAt.formatted(date: .abbreviated, time: .omitted)
        }

        if dueAt < startOfToday {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: dueAt, relativeTo: now)
        } else if dueAt < startOfTomorrow {
            return "Today"
        } else if dueAt < startOfDayAfterTomorrow {
            return "Tomorrow"
        } else if dueAt < endOfWeek {
            return calendar.weekdaySymbols[calendar.component(.weekday, from: dueAt) - 1]
        } else {
            return dueAt.formatted(date: .abbreviated, time: .omitted)
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "calendar")
                .font(.system(size: 9))
            Text(displayText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.white)
        )
    }
}

struct SourceBadgeCompact: View {
    let source: String
    let sourceLabel: String
    let sourceIcon: String

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: sourceIcon)
                .font(.system(size: 8))
            Text(sourceLabel)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.white)
        )
    }
}

struct PriorityBadgeCompact: View {
    let priority: String

    var body: some View {
        Text(priority.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.white)
            )
    }
}

// MARK: - Task Edit Sheet

enum TaskEditMode: Identifiable {
    case create
    case edit(TaskActionItem)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let task): return task.id
        }
    }
}

struct TaskEditSheet: View {
    let mode: TaskEditMode
    @ObservedObject var viewModel: TasksViewModel
    var onDismiss: (() -> Void)? = nil

    @State private var description: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var priority: String? = nil
    @State private var isSaving = false

    @Environment(\.dismiss) private var environmentDismiss

    private func dismissSheet() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var canSave: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        isEditing ? "Edit Task" : "New Task"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sheetHeader

            Divider()
                .background(OmiColors.border)

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Description field
                    descriptionField

                    // Due date picker
                    dueDateSection

                    // Priority picker
                    prioritySection
                }
                .padding(20)
            }

            Divider()
                .background(OmiColors.border)

            // Footer with buttons
            sheetFooter
        }
        .frame(width: 420, height: 380)
        .background(OmiColors.backgroundPrimary)
        .onAppear {
            if case .edit(let task) = mode {
                description = task.description
                if let due = task.dueAt {
                    hasDueDate = true
                    dueDate = due
                }
                priority = task.priority
            }
        }
    }

    private var sheetHeader: some View {
        HStack {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Spacer()

            DismissButton(action: dismissSheet)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            TextField("What needs to be done?", text: $description, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(3...6)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(OmiColors.border, lineWidth: 1)
                )

            Text("\(description.count)/200")
                .font(.system(size: 11))
                .foregroundColor(description.count > 200 ? .red : OmiColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var dueDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Due Date")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Toggle("", isOn: $hasDueDate)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if hasDueDate {
                DatePicker(
                    "",
                    selection: $dueDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
            }
        }
    }

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Priority")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            HStack(spacing: 8) {
                priorityButton(label: "None", value: nil)
                priorityButton(label: "Low", value: "low", color: OmiColors.textTertiary)
                priorityButton(label: "Medium", value: "medium", color: .orange)
                priorityButton(label: "High", value: "high", color: .red)
            }
        }
    }

    private func priorityButton(label: String, value: String?, color: Color = OmiColors.textSecondary) -> some View {
        let isSelected = priority == value

        return Button {
            priority = value
        } label: {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : color)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? (value != nil ? color : OmiColors.textSecondary) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.clear : OmiColors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var sheetFooter: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                dismissSheet()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                Task {
                    await saveTask()
                }
            } label: {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Text(isEditing ? "Save" : "Create")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(OmiColors.purplePrimary)
            .controlSize(.large)
            .disabled(!canSave || isSaving)
        }
        .padding(20)
    }

    private func saveTask() async {
        let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDescription.isEmpty else { return }

        isSaving = true

        let finalDueDate = hasDueDate ? dueDate : nil

        switch mode {
        case .create:
            await viewModel.createTask(
                description: trimmedDescription,
                dueAt: finalDueDate,
                priority: priority
            )
        case .edit(let task):
            await viewModel.updateTaskDetails(
                task,
                description: trimmedDescription,
                dueAt: finalDueDate,
                priority: priority
            )
        }

        isSaving = false
        dismissSheet()
    }
}

// MARK: - Date Filter Popover

struct DateFilterPopover: View {
    @ObservedObject var viewModel: TasksViewModel

    @State private var hasStartDate: Bool = false
    @State private var startDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var hasEndDate: Bool = false
    @State private var endDate: Date = Date()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Filter by Date")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                if viewModel.isFiltered {
                    Button {
                        viewModel.clearDateFilter()
                        dismiss()
                    } label: {
                        Text("Clear")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            // Start date
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("From")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)

                    Spacer()

                    Toggle("", isOn: $hasStartDate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                }

                if hasStartDate {
                    DatePicker(
                        "",
                        selection: $startDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
            }

            // End date
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("To")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)

                    Spacer()

                    Toggle("", isOn: $hasEndDate)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                }

                if hasEndDate {
                    DatePicker(
                        "",
                        selection: $endDate,
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
            }

            Divider()

            // Apply button
            Button {
                viewModel.applyDateFilter(
                    startDate: hasStartDate ? startDate : nil,
                    endDate: hasEndDate ? endDate : nil
                )
                dismiss()
            } label: {
                Text("Apply Filter")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OmiColors.purplePrimary)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasStartDate && !hasEndDate)
            .opacity(!hasStartDate && !hasEndDate ? 0.5 : 1)
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            if let start = viewModel.filterStartDate {
                hasStartDate = true
                startDate = start
            }
            if let end = viewModel.filterEndDate {
                hasEndDate = true
                endDate = end
            }
        }
    }
}
