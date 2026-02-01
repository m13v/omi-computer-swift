import SwiftUI

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

// MARK: - Tasks View Model

@MainActor
class TasksViewModel: ObservableObject {
    @Published var tasks: [TaskActionItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var showCompleted = false
    @Published var sortOption: TaskSortOption = .dueDate
    @Published var expandedCategories: Set<TaskCategory> = Set(TaskCategory.allCases)

    // MARK: - Computed Properties

    var displayTasks: [TaskActionItem] {
        let filtered = showCompleted
            ? tasks.filter { $0.completed }
            : tasks.filter { !$0.completed }
        return sortTasks(filtered)
    }

    var categorizedTasks: [TaskCategory: [TaskActionItem]] {
        var result: [TaskCategory: [TaskActionItem]] = [:]

        for category in TaskCategory.allCases {
            result[category] = []
        }

        for task in displayTasks {
            let category = categoryFor(task: task)
            result[category, default: []].append(task)
        }

        return result
    }

    var todoCount: Int {
        tasks.filter { !$0.completed }.count
    }

    var doneCount: Int {
        tasks.filter { $0.completed }.count
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

    // MARK: - Actions

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
        log("TasksViewModel: toggleTask called for id=\(task.id), setting completed=\(!task.completed)")
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                completed: !task.completed
            )
            log("TasksViewModel: toggleTask succeeded")
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
            tasks.removeAll { $0.id == task.id }
        } catch {
            self.error = error.localizedDescription
            logError("Failed to delete task", error: error)
        }
    }

    func toggleCategory(_ category: TaskCategory) {
        if expandedCategories.contains(category) {
            expandedCategories.remove(category)
        } else {
            expandedCategories.insert(category)
        }
    }
}

// MARK: - Tasks Page

struct TasksPage: View {
    @StateObject private var viewModel = TasksViewModel()

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
        .task {
            await viewModel.loadTasks()
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 12) {
            // To Do / Done toggle
            filterToggle

            Spacer()

            // Sort dropdown
            sortDropdown
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
                if viewModel.sortOption == .dueDate && !viewModel.showCompleted {
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
                    // Flat list for other sort options or completed view
                    ForEach(viewModel.displayTasks) { task in
                        TaskRow(task: task, viewModel: viewModel)
                    }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox with animation
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

            // Task content
            VStack(alignment: .leading, spacing: 6) {
                Text(task.description)
                    .font(.system(size: 14))
                    .foregroundColor(task.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                    .strikethrough(task.completed, color: OmiColors.textTertiary)
                    .lineLimit(3)

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

                    // Created date (if no due date)
                    if task.dueAt == nil {
                        Text(task.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
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
            Text(info.text)
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
