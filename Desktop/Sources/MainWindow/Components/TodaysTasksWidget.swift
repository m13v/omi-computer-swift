import SwiftUI

struct TodaysTasksWidget: View {
    let tasks: [TaskActionItem]
    let onToggleCompletion: (TaskActionItem) -> Void

    private var displayTasks: [TaskActionItem] {
        // Show max 5 tasks, prioritizing incomplete ones
        let incomplete = tasks.filter { !$0.completed }
        let completed = tasks.filter { $0.completed }
        return Array((incomplete + completed).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Today's Tasks")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                if !tasks.isEmpty {
                    Text("\(tasks.filter { !$0.completed }.count) remaining")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }

            if tasks.isEmpty {
                // Empty state
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(OmiColors.textQuaternary)
                    Text("No tasks due today")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Task list
                VStack(spacing: 8) {
                    ForEach(displayTasks) { task in
                        TaskRowView(task: task, onToggle: {
                            onToggleCompletion(task)
                        })
                    }
                }

                // Show all link if more than 5 tasks
                if tasks.count > 5 {
                    Button(action: {
                        // Navigate to Tasks tab
                        NotificationCenter.default.post(
                            name: NSNotification.Name("NavigateToTasks"),
                            object: nil
                        )
                    }) {
                        HStack {
                            Spacer()
                            Text("View all \(tasks.count) tasks")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(OmiColors.purplePrimary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10))
                                .foregroundColor(OmiColors.purplePrimary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
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

// MARK: - Task Row View

struct TaskRowView: View {
    let task: TaskActionItem
    let onToggle: () -> Void

    @State private var isToggling = false

    var body: some View {
        HStack(spacing: 10) {
            // Checkbox
            Button(action: {
                guard !isToggling else { return }
                isToggling = true
                onToggle()
                // Reset after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isToggling = false
                }
            }) {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(task.completed ? .green : OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isToggling)
            .opacity(isToggling ? 0.5 : 1)

            // Task description
            Text(task.description)
                .font(.system(size: 13))
                .foregroundColor(task.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                .strikethrough(task.completed)
                .lineLimit(2)

            Spacer()

            // Priority indicator
            if let priority = task.priority {
                Circle()
                    .fill(priorityColor(priority))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(task.completed ? OmiColors.backgroundQuaternary.opacity(0.3) : Color.clear)
        )
    }

    private func priorityColor(_ priority: String) -> Color {
        switch priority {
        case "high": return .red
        case "medium": return .orange
        case "low": return .blue
        default: return OmiColors.textQuaternary
        }
    }
}

#Preview {
    TodaysTasksWidget(
        tasks: [],
        onToggleCompletion: { _ in }
    )
    .frame(width: 350)
    .padding()
    .background(OmiColors.backgroundPrimary)
}
