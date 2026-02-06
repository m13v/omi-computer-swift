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

// MARK: - Task Filter Tag

enum TaskFilterGroup: String, CaseIterable {
    case status = "Status"
    case category = "Category"
    case source = "Source"
    case priority = "Priority"
}

enum TaskFilterTag: String, CaseIterable, Identifiable, Hashable {
    // Status
    case todo
    case done

    // Category (matches TaskClassification)
    case personal
    case work
    case feature
    case bug
    case code
    case research
    case communication
    case finance
    case health
    case other

    // Source
    case sourceScreen
    case sourceOmi
    case sourceDesktop
    case sourceManual

    // Priority
    case priorityHigh
    case priorityMedium
    case priorityLow

    var id: String { rawValue }

    var group: TaskFilterGroup {
        switch self {
        case .todo, .done: return .status
        case .personal, .work, .feature, .bug, .code, .research, .communication, .finance, .health, .other: return .category
        case .sourceScreen, .sourceOmi, .sourceDesktop, .sourceManual: return .source
        case .priorityHigh, .priorityMedium, .priorityLow: return .priority
        }
    }

    var displayName: String {
        switch self {
        case .todo: return "To Do"
        case .done: return "Done"
        case .personal: return "Personal"
        case .work: return "Work"
        case .feature: return "Feature"
        case .bug: return "Bug"
        case .code: return "Code"
        case .research: return "Research"
        case .communication: return "Communication"
        case .finance: return "Finance"
        case .health: return "Health"
        case .other: return "Other"
        case .sourceScreen: return "Screen"
        case .sourceOmi: return "OMI"
        case .sourceDesktop: return "Desktop"
        case .sourceManual: return "Manual"
        case .priorityHigh: return "High"
        case .priorityMedium: return "Medium"
        case .priorityLow: return "Low"
        }
    }

    var icon: String {
        switch self {
        case .todo: return "circle"
        case .done: return "checkmark.circle.fill"
        case .personal: return "person.fill"
        case .work: return "briefcase.fill"
        case .feature: return "sparkles"
        case .bug: return "ladybug.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .research: return "magnifyingglass"
        case .communication: return "message.fill"
        case .finance: return "dollarsign.circle.fill"
        case .health: return "heart.fill"
        case .other: return "folder.fill"
        case .sourceScreen: return "camera.fill"
        case .sourceOmi: return "waveform"
        case .sourceDesktop: return "desktopcomputer"
        case .sourceManual: return "square.and.pencil"
        case .priorityHigh: return "flag.fill"
        case .priorityMedium: return "flag"
        case .priorityLow: return "flag"
        }
    }

    /// Check if a task matches this filter tag
    func matches(_ task: TaskActionItem) -> Bool {
        switch self {
        case .todo: return !task.completed
        case .done: return task.completed
        case .personal: return task.category == "personal"
        case .work: return task.category == "work"
        case .feature: return task.category == "feature"
        case .bug: return task.category == "bug"
        case .code: return task.category == "code"
        case .research: return task.category == "research"
        case .communication: return task.category == "communication"
        case .finance: return task.category == "finance"
        case .health: return task.category == "health"
        case .other: return task.category == "other"
        case .sourceScreen: return task.source == "screenshot"
        case .sourceOmi: return task.source == "transcription:omi"
        case .sourceDesktop: return task.source == "transcription:desktop"
        case .sourceManual: return task.source == "manual"
        case .priorityHigh: return task.priority == "high"
        case .priorityMedium: return task.priority == "medium"
        case .priorityLow: return task.priority == "low"
        }
    }

    /// Tags grouped by their filter group
    static func tags(for group: TaskFilterGroup) -> [TaskFilterTag] {
        allCases.filter { $0.group == group }
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
        didSet {
            if oldValue != showCompleted {
                // Load appropriate tasks from server when switching tabs
                Task {
                    if showCompleted {
                        await store.loadCompletedTasks()
                    } else {
                        await store.loadIncompleteTasks(showAll: true)
                    }
                }
            }
            recomputeDisplayCaches()
        }
    }
    @Published var sortOption: TaskSortOption = .dueDate {
        didSet { recomputeDisplayCaches() }
    }
    @Published var expandedCategories: Set<TaskCategory> = Set(TaskCategory.allCases)

    // Filter tags (Memories-style dropdown)
    @Published var selectedTags: Set<TaskFilterTag> = [] {
        didSet {
            // Map status tags to showCompleted for server-side loading
            let hasStatusFilter = selectedTags.contains(where: { $0.group == .status })
            if hasStatusFilter {
                let wantsDone = selectedTags.contains(.done)
                let wantsTodo = selectedTags.contains(.todo)
                if wantsDone && !wantsTodo && !showCompleted {
                    showCompleted = true
                } else if wantsTodo && !wantsDone && showCompleted {
                    showCompleted = false
                } else if wantsDone && wantsTodo {
                    // Both selected - load both
                    if !showCompleted {
                        Task { await store.loadCompletedTasks() }
                    }
                }
            }
            recomputeDisplayCaches()
        }
    }

    /// Cached tag counts - recomputed when tasks change
    @Published private(set) var tagCounts: [TaskFilterTag: Int] = [:]

    /// Count tasks for a specific tag
    func tagCount(_ tag: TaskFilterTag) -> Int {
        tagCounts[tag] ?? 0
    }

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

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Cached Properties (avoid recomputation on every render)

    @Published private(set) var displayTasks: [TaskActionItem] = []
    @Published private(set) var categorizedTasks: [TaskCategory: [TaskActionItem]] = [:]
    @Published private(set) var todoCount: Int = 0
    @Published private(set) var doneCount: Int = 0

    // Delegate to store
    var isLoading: Bool { store.isLoading }
    var isLoadingMore: Bool { store.isLoadingMore }
    var hasMoreTasks: Bool {
        showCompleted ? store.hasMoreCompletedTasks : store.hasMoreIncompleteTasks
    }
    var error: String? { store.error }
    var tasks: [TaskActionItem] { store.tasks }

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

    /// Get the source tasks based on current view (completed vs incomplete)
    private func getSourceTasks() -> [TaskActionItem] {
        // If both status tags selected or no status tags, combine both lists
        let statusTags = selectedTags.filter { $0.group == .status }
        if statusTags.isEmpty || (statusTags.contains(.todo) && statusTags.contains(.done)) {
            return store.incompleteTasks + store.completedTasks
        } else if statusTags.contains(.done) {
            return store.completedTasks
        } else {
            return store.incompleteTasks
        }
    }

    /// Apply selected filter tags to tasks (non-status tags)
    private func applyTagFilters(_ tasks: [TaskActionItem]) -> [TaskActionItem] {
        let nonStatusTags = selectedTags.filter { $0.group != .status }
        guard !nonStatusTags.isEmpty else { return tasks }

        // Group tags by their filter group, then AND between groups, OR within a group
        let tagsByGroup = Dictionary(grouping: nonStatusTags) { $0.group }

        return tasks.filter { task in
            tagsByGroup.allSatisfy { (_, groupTags) in
                groupTags.contains { $0.matches(task) }
            }
        }
    }

    /// Recompute all caches when tasks change
    private func recomputeAllCaches() {
        // Counts come directly from store
        todoCount = store.incompleteTasks.count
        doneCount = store.completedTasks.count

        // Recompute tag counts from all tasks
        let allTasks = store.incompleteTasks + store.completedTasks
        var counts: [TaskFilterTag: Int] = [:]
        for tag in TaskFilterTag.allCases {
            counts[tag] = allTasks.filter { tag.matches($0) }.count
        }
        tagCounts = counts

        // Recompute display caches
        recomputeDisplayCaches()
    }

    /// Recompute display-related caches when filters or sort change
    private func recomputeDisplayCaches() {
        // Get tasks from appropriate list based on status filter
        let sourceTasks = getSourceTasks()

        // Apply tag filters (category, source, priority)
        let filteredTasks = applyTagFilters(sourceTasks)

        // Sort and store
        displayTasks = sortTasks(filteredTasks)

        // Compute categorizedTasks for category view
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

    // Filter popover state
    @State private var showFilterPopover = false
    @State private var pendingSelectedTags: Set<TaskFilterTag> = []
    @State private var filterSearchText = ""

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
        .onAppear {
            // If tasks are already loaded, notify sidebar to clear loading indicator
            if !viewModel.isLoading {
                NotificationCenter.default.post(name: .tasksPageDidLoad, object: nil)
            }
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            if !viewModel.isMultiSelectMode {
                filterDropdownButton
            } else {
                multiSelectControls
            }

            Spacer()

            if viewModel.isMultiSelectMode {
                if !viewModel.selectedTaskIds.isEmpty {
                    deleteSelectedButton
                }
            } else {
                addTaskButton
            }

            if viewModel.isMultiSelectMode {
                cancelMultiSelectButton
            } else {
                sortDropdown
                taskSettingsButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Filter Dropdown

    private var filterLabel: String {
        if viewModel.selectedTags.isEmpty {
            return "All"
        } else if viewModel.selectedTags.count == 1 {
            return viewModel.selectedTags.first!.displayName
        } else {
            return "\(viewModel.selectedTags.count) selected"
        }
    }

    /// Filtered tags based on search text, grouped by filter group
    private func filteredTags(for group: TaskFilterGroup) -> [TaskFilterTag] {
        let tags = TaskFilterTag.tags(for: group)
        if filterSearchText.isEmpty {
            return tags.sorted { viewModel.tagCount($0) > viewModel.tagCount($1) }
        }
        return tags
            .filter { $0.displayName.localizedCaseInsensitiveContains(filterSearchText) }
            .sorted { viewModel.tagCount($0) > viewModel.tagCount($1) }
    }

    private var filterDropdownButton: some View {
        Button {
            pendingSelectedTags = viewModel.selectedTags
            filterSearchText = ""
            showFilterPopover = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12))
                Text(filterLabel)
                    .font(.system(size: 13, weight: viewModel.selectedTags.isEmpty ? .regular : .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .foregroundColor(viewModel.selectedTags.isEmpty ? OmiColors.textSecondary : OmiColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(viewModel.selectedTags.isEmpty ? OmiColors.backgroundSecondary : Color.white)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(viewModel.selectedTags.isEmpty ? Color.clear : OmiColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showFilterPopover, arrowEdge: .bottom) {
            filterPopover
        }
    }

    private var filterPopover: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)
                    .font(.system(size: 12))

                TextField("Search filters...", text: $filterSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textPrimary)

                if !filterSearchText.isEmpty {
                    Button {
                        filterSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(OmiColors.textTertiary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(6)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 12)

            // Tag list grouped by filter group
            ScrollView {
                VStack(spacing: 2) {
                    // "All" option
                    Button {
                        pendingSelectedTags.removeAll()
                    } label: {
                        HStack {
                            Image(systemName: "tray.full")
                                .font(.system(size: 12))
                                .frame(width: 20)
                            Text("All")
                                .font(.system(size: 13))
                            Spacer()
                            Text("\(viewModel.todoCount + viewModel.doneCount)")
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OmiColors.backgroundTertiary)
                                .cornerRadius(4)
                            if pendingSelectedTags.isEmpty {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                            }
                        }
                        .foregroundColor(OmiColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(pendingSelectedTags.isEmpty ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear)
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Groups
                    ForEach(TaskFilterGroup.allCases, id: \.self) { group in
                        let tags = filteredTags(for: group)
                        if !tags.isEmpty {
                            Divider()
                                .padding(.vertical, 4)

                            // Group header
                            Text(group.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(OmiColors.textTertiary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            // Tags in group
                            ForEach(tags) { tag in
                                let isSelected = pendingSelectedTags.contains(tag)
                                let count = viewModel.tagCount(tag)

                                Button {
                                    if isSelected {
                                        pendingSelectedTags.remove(tag)
                                    } else {
                                        pendingSelectedTags.insert(tag)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: tag.icon)
                                            .font(.system(size: 12))
                                            .frame(width: 20)
                                        Text(tag.displayName)
                                            .font(.system(size: 13))
                                        Spacer()
                                        Text("\(count)")
                                            .font(.system(size: 11))
                                            .foregroundColor(OmiColors.textTertiary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(OmiColors.backgroundTertiary)
                                            .cornerRadius(4)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.white)
                                        }
                                    }
                                    .foregroundColor(OmiColors.textPrimary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(isSelected ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear)
                                    .cornerRadius(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 350)

            Divider()
                .padding(.horizontal, 12)

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    pendingSelectedTags.removeAll()
                } label: {
                    Text("Clear")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.selectedTags = pendingSelectedTags
                    showFilterPopover = false
                } label: {
                    Text("Apply")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
        .frame(width: 280)
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
            .foregroundColor(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(OmiColors.border, lineWidth: 1)
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

    private var taskSettingsButton: some View {
        Button {
            NotificationCenter.default.post(
                name: .navigateToTaskSettings,
                object: nil
            )
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textSecondary)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundSecondary)
                )
        }
        .buttonStyle(.plain)
        .help("Task Settings")
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
            Image(systemName: viewModel.selectedTags.isEmpty ? "tray.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text(viewModel.selectedTags.isEmpty ? "All Caught Up!" : "No Matching Tasks")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text(viewModel.selectedTags.isEmpty ? "You have no tasks yet" : "Try adjusting your filters")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)

            if !viewModel.selectedTags.isEmpty {
                Button("Clear Filters") {
                    withAnimation {
                        viewModel.selectedTags.removeAll()
                    }
                }
                .buttonStyle(.bordered)
                .tint(OmiColors.textSecondary)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tasks List View

    private var tasksListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Show tasks grouped by category when sorting by due date
                // Show category grouping when sorting by due date and not viewing only completed tasks
                let onlyDone = viewModel.selectedTags.contains(.done) && !viewModel.selectedTags.contains(.todo)
                if viewModel.sortOption == .dueDate && !onlyDone && !viewModel.isMultiSelectMode {
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
    @State private var showAgentDetail = false

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

    /// Check if task was created less than 1 minute ago (newly added)
    private var isNewlyCreated: Bool {
        Date().timeIntervalSince(task.createdAt) < 60
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
            .sheet(isPresented: $showAgentDetail) {
                TaskAgentDetailView(
                    task: task,
                    onDismiss: { showAgentDetail = false }
                )
            }
    }

    // MARK: - Swipeable Content

    private var swipeableContent: some View {
        ZStack(alignment: .trailing) {
            // Background revealed when swiping left
            if swipeOffset < 0 {
                if indentLevel > 0 {
                    // Indented task: swipe left to outdent
                    outdentBackground
                } else {
                    // Not indented: swipe left to delete
                    deleteBackground
                }
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
                                // Swiping left (delete or outdent)
                                swipeOffset = translation * 0.8
                            } else if translation > 0 && indentLevel < 3 {
                                // Swiping right (indent) - only if can indent more
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
        .background(OmiColors.textSecondary)
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
        let swipedLeftPastThreshold = swipeOffset < -deleteThreshold || velocity < -500
        let swipedRightPastThreshold = swipeOffset > indentThreshold || velocity > 500

        if swipedLeftPastThreshold {
            if indentLevel > 0 {
                // Outdent (decrease indent) and snap back
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    swipeOffset = 0
                }
                viewModel.decrementIndent(for: task.id)
            } else {
                // Delete - animate off screen
                withAnimation(.easeOut(duration: 0.2)) {
                    swipeOffset = -400
                    rowOpacity = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    Task {
                        await viewModel.deleteTask(task)
                    }
                }
            }
        } else if swipedRightPastThreshold && indentLevel < 3 {
            // Indent (increase indent) and snap back
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

                    // Category badge (classification like feature, bug, code, etc.)
                    if let taskCategory = task.category {
                        TaskClassificationBadge(category: taskCategory)
                    }

                    // Agent status indicator (for code-related tasks with active agents)
                    if task.shouldTriggerAgent {
                        AgentStatusIndicator(taskId: task.id)
                    }

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

            // Hover actions: agent, indent controls, and delete
            if isHovering && !viewModel.isMultiSelectMode {
                HStack(spacing: 4) {
                    // Agent button (for code-related tasks)
                    if task.shouldTriggerAgent {
                        Button {
                            showAgentDetail = true
                        } label: {
                            Image(systemName: "terminal")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("View Agent Details")
                    }

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
                .fill(isHovering || isDragging ? OmiColors.backgroundTertiary : (isNewlyCreated ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundPrimary))
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
        .foregroundColor(OmiColors.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(OmiColors.backgroundTertiary)
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
        .foregroundColor(OmiColors.textSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(OmiColors.backgroundTertiary)
        )
    }
}

struct PriorityBadgeCompact: View {
    let priority: String

    var body: some View {
        Text(priority.capitalized)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(OmiColors.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(OmiColors.backgroundTertiary)
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
            .tint(OmiColors.textPrimary)
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

