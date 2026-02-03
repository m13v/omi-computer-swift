import SwiftUI

struct GoalsWidget: View {
    let goals: [Goal]
    let onAddGoal: () -> Void
    let onEditGoal: (Goal) -> Void
    let onUpdateProgress: (Goal, Double) -> Void
    let onDeleteGoal: (Goal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Goals")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                // Add goal button (only if less than 3 goals)
                if goals.count < 3 {
                    Button(action: onAddGoal) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(OmiColors.purplePrimary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if goals.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "target")
                        .font(.system(size: 28))
                        .foregroundColor(OmiColors.textQuaternary)
                    Text("No goals set")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                    Text("Add up to 3 goals to track")
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textQuaternary)

                    Button(action: onAddGoal) {
                        Text("Add Goal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.purplePrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(OmiColors.purplePrimary.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Goals list
                VStack(spacing: 12) {
                    ForEach(goals) { goal in
                        GoalRowView(
                            goal: goal,
                            onEdit: { onEditGoal(goal) },
                            onUpdateProgress: { value in onUpdateProgress(goal, value) },
                            onDelete: { onDeleteGoal(goal) }
                        )
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(OmiColors.backgroundTertiary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(OmiColors.backgroundQuaternary.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - Goal Row View

struct GoalRowView: View {
    let goal: Goal
    let onEdit: () -> Void
    let onUpdateProgress: (Double) -> Void
    let onDelete: () -> Void

    @State private var showingActions = false

    private var progressColor: Color {
        let progress = goal.progress
        if progress >= 100 {
            return .green
        } else if progress >= 75 {
            return Color(red: 0.5, green: 0.8, blue: 0.2) // Lime
        } else if progress >= 50 {
            return Color(red: 0.8, green: 0.8, blue: 0.0) // Yellow
        } else if progress >= 25 {
            return .orange
        } else {
            return OmiColors.textQuaternary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row with emoji
            HStack {
                Text(goalEmoji)
                    .font(.system(size: 16))

                Text(goal.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textPrimary)
                    .lineLimit(1)

                Spacer()

                // Progress percentage
                Text("\(Int(goal.progress))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(progressColor)

                // Actions menu
                Menu {
                    if goal.goalType != .boolean {
                        Button(action: {
                            let newValue = min(goal.currentValue + 1, goal.maxValue)
                            onUpdateProgress(newValue)
                        }) {
                            Label("Increment", systemImage: "plus")
                        }
                    }

                    if goal.goalType == .boolean {
                        Button(action: {
                            let newValue = goal.currentValue >= goal.targetValue ? 0 : goal.targetValue
                            onUpdateProgress(newValue)
                        }) {
                            Label(goal.isCompleted ? "Mark Incomplete" : "Mark Complete", systemImage: goal.isCompleted ? "xmark.circle" : "checkmark.circle")
                        }
                    }

                    Divider()

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete Goal", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(OmiColors.backgroundQuaternary)
                        .frame(height: 8)

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressColor)
                        .frame(width: max(0, geometry.size.width * min(goal.progress / 100, 1.0)), height: 8)
                }
            }
            .frame(height: 8)

            // Progress text
            Text(goal.progressText)
                .font(.system(size: 11))
                .foregroundColor(OmiColors.textTertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(OmiColors.backgroundSecondary.opacity(0.5))
        )
    }

    private var goalEmoji: String {
        // Try to pick an emoji based on the goal title keywords
        let title = goal.title.lowercased()
        if title.contains("exercise") || title.contains("workout") || title.contains("gym") {
            return "💪"
        } else if title.contains("read") || title.contains("book") {
            return "📖"
        } else if title.contains("meditat") || title.contains("mindful") {
            return "🧘"
        } else if title.contains("water") || title.contains("drink") {
            return "💧"
        } else if title.contains("sleep") || title.contains("bed") {
            return "😴"
        } else if title.contains("walk") || title.contains("step") {
            return "🚶"
        } else if title.contains("learn") || title.contains("study") {
            return "📚"
        } else if title.contains("code") || title.contains("program") {
            return "💻"
        } else if title.contains("call") || title.contains("family") {
            return "📞"
        } else if title.contains("clean") || title.contains("organize") {
            return "🧹"
        } else if title.contains("save") || title.contains("money") || title.contains("budget") {
            return "💰"
        } else if title.contains("eat") || title.contains("diet") || title.contains("healthy") {
            return "🥗"
        } else {
            return "🎯"
        }
    }
}

#Preview {
    GoalsWidget(
        goals: [],
        onAddGoal: {},
        onEditGoal: { _ in },
        onUpdateProgress: { _, _ in },
        onDeleteGoal: { _ in }
    )
    .frame(width: 350)
    .padding()
    .background(OmiColors.backgroundPrimary)
}
