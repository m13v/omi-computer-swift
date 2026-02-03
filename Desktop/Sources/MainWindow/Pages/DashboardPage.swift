import SwiftUI

// MARK: - Dashboard View Model

@MainActor
class DashboardViewModel: ObservableObject {
    @Published var dailyScore: DailyScore?
    @Published var todaysTasks: [TaskActionItem] = []
    @Published var goals: [Goal] = []
    @Published var isLoading = false
    @Published var error: String?

    // Goal editing state
    @Published var showingCreateGoal = false
    @Published var editingGoal: Goal? = nil

    func loadDashboardData() async {
        isLoading = true
        error = nil

        // Load all data in parallel
        async let scoreTask = loadDailyScore()
        async let tasksTask = loadTodaysTasks()
        async let goalsTask = loadGoals()

        let _ = await (scoreTask, tasksTask, goalsTask)

        isLoading = false
    }

    private func loadDailyScore() async {
        do {
            dailyScore = try await APIClient.shared.getDailyScore()
        } catch {
            logError("Failed to load daily score", error: error)
        }
    }

    private func loadTodaysTasks() async {
        do {
            let calendar = Calendar.current
            let startOfDay = calendar.startOfDay(for: Date())
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

            let response = try await APIClient.shared.getActionItems(
                limit: 10,
                dueStartDate: startOfDay,
                dueEndDate: endOfDay
            )
            todaysTasks = response.items
        } catch {
            logError("Failed to load today's tasks", error: error)
        }
    }

    private func loadGoals() async {
        do {
            goals = try await APIClient.shared.getGoals()
        } catch {
            logError("Failed to load goals", error: error)
        }
    }

    func toggleTaskCompletion(_ task: TaskActionItem) async {
        do {
            let updated = try await APIClient.shared.updateActionItem(
                id: task.id,
                completed: !task.completed
            )
            if let index = todaysTasks.firstIndex(where: { $0.id == task.id }) {
                todaysTasks[index] = updated
            }
            // Reload daily score after task completion change
            await loadDailyScore()
        } catch {
            logError("Failed to toggle task completion", error: error)
        }
    }

    func createGoal(title: String, goalType: GoalType, targetValue: Double, unit: String?) async {
        do {
            let goal = try await APIClient.shared.createGoal(
                title: title,
                goalType: goalType,
                targetValue: targetValue,
                unit: unit
            )
            goals.insert(goal, at: 0)
            if goals.count > 3 {
                goals = Array(goals.prefix(3))
            }
        } catch {
            logError("Failed to create goal", error: error)
        }
    }

    func updateGoalProgress(_ goal: Goal, currentValue: Double) async {
        do {
            let updated = try await APIClient.shared.updateGoalProgress(
                goalId: goal.id,
                currentValue: currentValue
            )
            if let index = goals.firstIndex(where: { $0.id == goal.id }) {
                goals[index] = updated
            }
        } catch {
            logError("Failed to update goal progress", error: error)
        }
    }

    func deleteGoal(_ goal: Goal) async {
        do {
            try await APIClient.shared.deleteGoal(id: goal.id)
            goals.removeAll { $0.id == goal.id }
        } catch {
            logError("Failed to delete goal", error: error)
        }
    }
}

// MARK: - Dashboard Page

struct DashboardPage: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dashboard")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(formattedDate)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    if viewModel.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }

                    Button(action: {
                        Task {
                            await viewModel.loadDashboardData()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // Widgets
                HStack(alignment: .top, spacing: 20) {
                    // Left column: Daily Score + Today's Tasks
                    VStack(spacing: 20) {
                        DailyScoreWidget(dailyScore: viewModel.dailyScore)
                        TodaysTasksWidget(
                            tasks: viewModel.todaysTasks,
                            onToggleCompletion: { task in
                                Task {
                                    await viewModel.toggleTaskCompletion(task)
                                }
                            }
                        )
                    }
                    .frame(maxWidth: .infinity)

                    // Right column: Goals
                    GoalsWidget(
                        goals: viewModel.goals,
                        onAddGoal: { viewModel.showingCreateGoal = true },
                        onEditGoal: { goal in viewModel.editingGoal = goal },
                        onUpdateProgress: { goal, value in
                            Task {
                                await viewModel.updateGoalProgress(goal, currentValue: value)
                            }
                        },
                        onDeleteGoal: { goal in
                            Task {
                                await viewModel.deleteGoal(goal)
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            Task {
                await viewModel.loadDashboardData()
            }
        }
        .sheet(isPresented: $viewModel.showingCreateGoal) {
            CreateGoalSheet(
                onSave: { title, goalType, targetValue, unit in
                    Task {
                        await viewModel.createGoal(
                            title: title,
                            goalType: goalType,
                            targetValue: targetValue,
                            unit: unit
                        )
                    }
                }
            )
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: Date())
    }
}

// MARK: - Create Goal Sheet

struct CreateGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, GoalType, Double, String?) -> Void

    @State private var title = ""
    @State private var goalType: GoalType = .boolean
    @State private var targetValue: Double = 100
    @State private var unit = ""

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text("Create Goal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            // Title
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OmiColors.textSecondary)
                TextField("e.g., Exercise 3 times this week", text: $title)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(OmiColors.backgroundTertiary)
                    .cornerRadius(8)
            }

            // Goal Type
            VStack(alignment: .leading, spacing: 6) {
                Text("Type")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OmiColors.textSecondary)
                Picker("", selection: $goalType) {
                    ForEach(GoalType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Target Value (for non-boolean)
            if goalType != .boolean {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)
                        TextField("100", value: $targetValue, format: .number)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(OmiColors.backgroundTertiary)
                            .cornerRadius(8)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unit (optional)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)
                        TextField("e.g., hours, pages", text: $unit)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(OmiColors.backgroundTertiary)
                            .cornerRadius(8)
                    }
                }
            }

            Spacer()

            // Save button
            Button(action: {
                let finalTarget = goalType == .boolean ? 1.0 : targetValue
                onSave(title, goalType, finalTarget, unit.isEmpty ? nil : unit)
                dismiss()
            }) {
                Text("Create Goal")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(OmiColors.purplePrimary)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .disabled(title.isEmpty)
            .opacity(title.isEmpty ? 0.5 : 1)
        }
        .padding(24)
        .frame(width: 400, height: 350)
        .background(OmiColors.backgroundSecondary)
    }
}

#Preview {
    DashboardPage()
        .frame(width: 800, height: 600)
        .background(OmiColors.backgroundPrimary)
}
