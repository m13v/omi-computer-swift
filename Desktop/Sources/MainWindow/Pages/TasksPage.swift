import SwiftUI
import Combine

// MARK: - Task Category (by due date)

enum TaskCategory: String, CaseIterable {
    case overdue = "Overdue"
    case today = "Today"
    case tomorrow = "Tomorrow"
    case later = "Later"
    case noDeadline = "No Deadline"

    var icon: String {
        switch self {
        case .overdue: return "exclamationmark.circle.fill"
        case .today: return "sun.max.fill"
        case .tomorrow: return "sunrise.fill"
        case .later: return "calendar"
        case .noDeadline: return "tray.fill"
        }
    }

    var color: Color {
        switch self {
        case .overdue: return .red
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
    @Published var expandedCategories: Set<TaskCategory> = Set(TaskCategory.allCases)

    // Create/Edit task state
    @Published var showingCreateTask = false
    @Published var editingTask: TaskActionItem? = nil

    // Multi-select state
    @Published var isMultiSelectMode = false
    @Published var selectedTaskIds: Set<String> = []

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
        // Forward store changes to trigger view updates and recompute caches
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeAllCaches()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
        // Compute displayTasks
        let display = showCompleted
            ? filtered.filter { $0.completed }
            : filtered.filter { !$0.completed }
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

        if dueAt < startOfToday {
            return .overdue
        } else if dueAt < startOfTomorrow {
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
                // Tasks with due dates first
                switch (a.dueAt, b.dueAt) {
                case (nil, nil):
                    return a.createdAt > b.createdAt
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let aDate?, let bDate?):
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
        .sheet(isPresented: $viewModel.showingCreateTask) {
            TaskEditSheet(
                mode: .create,
                viewModel: viewModel
            )
        }
        .sheet(item: $viewModel.editingTask) { task in
            TaskEditSheet(
                mode: .edit(task),
                viewModel: viewModel
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
        return viewModel.showCompleted ? "Complete a task to see it here" : "You have no pending tasks"
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
            .animation(.easeInOut(duration: 0.3), value: viewModel.displayTasks.map(\.id))
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

            // Tasks in category
            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, viewModel: viewModel)
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

    private var isSelected: Bool {
        viewModel.selectedTaskIds.contains(task.id)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                .padding(.top, 2)
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
                .padding(.top, 2)
            }

            // Task content (tappable for editing or selection)
            Button {
                if viewModel.isMultiSelectMode {
                    viewModel.toggleTaskSelection(task)
                } else {
                    viewModel.editingTask = task
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.description)
                        .font(.system(size: 14))
                        .foregroundColor(task.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                        .strikethrough(task.completed, color: OmiColors.textTertiary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 8) {
                        // Due date badge (color-coded)
                        if let dueAt = task.dueAt {
                            DueDateBadge(dueAt: dueAt, isCompleted: task.completed)
                        }

                        // Source badge
                        if let source = task.source {
                            SourceBadge(source: source, sourceLabel: task.sourceLabel, sourceIcon: task.sourceIcon)
                        }

                        // Priority badge
                        if let priority = task.priority, priority != "low" {
                            PriorityBadge(priority: priority)
                        }

                        // Created date with full timestamp
                        Text("created: \(task.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

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
            return ("Overdue", .red)
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

    @State private var description: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var priority: String? = nil
    @State private var isSaving = false

    @Environment(\.dismiss) private var dismiss

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

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
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
                dismiss()
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
        dismiss()
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
