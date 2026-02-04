import SwiftUI

// MARK: - Goals Widget

struct GoalsWidget: View {
    let goals: [Goal]
    let onCreateGoal: (String, Double, Double) -> Void  // (title, currentValue, targetValue)
    let onUpdateProgress: (Goal, Double) -> Void
    let onDeleteGoal: (Goal) -> Void

    @State private var editingGoal: Goal? = nil
    @State private var showingCreateSheet = false

    // AI Features
    @State private var showingSuggestionSheet = false
    @State private var showingAdviceSheet = false
    @State private var selectedGoalForAdvice: Goal? = nil

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
                    Button(action: { showingCreateSheet = true }) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if goals.isEmpty {
                // Empty state - clickable to add
                Button(action: { showingCreateSheet = true }) {
                    HStack {
                        Spacer()
                        Image(systemName: "plus")
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textTertiary)
                        Text("Tap to add goal")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                .buttonStyle(.plain)
            } else {
                // Goals list
                VStack(spacing: 12) {
                    ForEach(goals) { goal in
                        GoalRowView(
                            goal: goal,
                            onTap: { editingGoal = goal },
                            onUpdateProgress: { value in onUpdateProgress(goal, value) },
                            onDelete: { onDeleteGoal(goal) }
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(OmiColors.backgroundTertiary.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(OmiColors.backgroundTertiary.opacity(0.5), lineWidth: 1)
                )
        )
        .sheet(isPresented: $showingCreateSheet) {
            GoalEditSheet(
                goal: nil,
                onSave: { title, current, target in
                    onCreateGoal(title, current, target)
                },
                onDelete: nil,
                onDismiss: { showingCreateSheet = false }
            )
        }
        .sheet(item: $editingGoal) { goal in
            GoalEditSheet(
                goal: goal,
                onSave: { title, current, target in
                    onUpdateProgress(goal, current)
                },
                onDelete: {
                    onDeleteGoal(goal)
                },
                onDismiss: { editingGoal = nil }
            )
        }
    }

}

// MARK: - Goal Row View

struct GoalRowView: View {
    let goal: Goal
    let onTap: () -> Void
    let onUpdateProgress: (Double) -> Void
    let onDelete: () -> Void

    private var progressColor: Color {
        let progress = goal.progress / 100.0  // Convert to 0-1 range
        if progress >= 0.8 {
            return Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E Green
        } else if progress >= 0.6 {
            return Color(red: 0.518, green: 0.8, blue: 0.086) // #84CC16 Lime
        } else if progress >= 0.4 {
            return Color(red: 0.984, green: 0.749, blue: 0.141) // #FBBF24 Yellow
        } else if progress >= 0.2 {
            return Color(red: 0.976, green: 0.451, blue: 0.086) // #F97316 Orange
        } else {
            return OmiColors.textTertiary
        }
    }

    private var progressText: String {
        let current = goal.currentValue == goal.currentValue.rounded()
            ? String(format: "%.0f", goal.currentValue)
            : String(format: "%.1f", goal.currentValue)
        let target = goal.targetValue == goal.targetValue.rounded()
            ? String(format: "%.0f", goal.targetValue)
            : String(format: "%.1f", goal.targetValue)
        return "\(current)/\(target)"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Emoji icon
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundTertiary.opacity(0.6))
                        .frame(width: 32, height: 32)
                    Text(goalEmoji)
                        .font(.system(size: 16))
                }

                // Content
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(goal.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        // Progress value (current/target)
                        Text(progressText)
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            RoundedRectangle(cornerRadius: 2)
                                .fill(OmiColors.backgroundTertiary.opacity(0.5))
                                .frame(height: 4)

                            // Progress
                            RoundedRectangle(cornerRadius: 2)
                                .fill(progressColor)
                                .frame(width: max(0, geometry.size.width * min(goal.progress / 100, 1.0)), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.backgroundTertiary.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }

    private var goalEmoji: String {
        let title = goal.title.lowercased()

        // Money/Revenue
        if title.contains("revenue") || title.contains("money") || title.contains("income") ||
           title.contains("profit") || title.contains("sales") || title.contains("$") ||
           title.contains("dollar") || title.contains("earn") {
            return "💰"
        }
        // Growth/Users
        if title.contains("users") || title.contains("customers") || title.contains("clients") ||
           title.contains("subscribers") || title.contains("followers") || title.contains("growth") ||
           title.contains("million") || title.contains("1m") || title.contains("10k") ||
           title.contains("100k") || title.contains("mrr") || title.contains("arr") {
            return "🚀"
        }
        // Startup/Business
        if title.contains("startup") || title.contains("launch") || title.contains("business") ||
           title.contains("company") {
            return "🏆"
        }
        // Investment
        if title.contains("invest") || title.contains("stock") || title.contains("crypto") ||
           title.contains("trading") {
            return "📈"
        }
        // Workout/Gym
        if title.contains("workout") || title.contains("gym") || title.contains("exercise") ||
           title.contains("lift") || title.contains("muscle") || title.contains("strength") ||
           title.contains("pushup") || title.contains("pullup") {
            return "💪"
        }
        // Running/Cardio
        if title.contains("run") || title.contains("marathon") || title.contains("jog") ||
           title.contains("cardio") || title.contains("steps") || title.contains("walk") ||
           title.contains("mile") || title.contains("km") {
            return "🏃"
        }
        // Weight/Diet
        if title.contains("weight") || title.contains("lose") || title.contains("fat") ||
           title.contains("diet") || title.contains("calories") || title.contains("kg") ||
           title.contains("lbs") || title.contains("pounds") {
            return "⚖️"
        }
        // Meditation/Yoga
        if title.contains("meditat") || title.contains("mindful") || title.contains("yoga") ||
           title.contains("breath") || title.contains("calm") || title.contains("peace") ||
           title.contains("zen") {
            return "🧘"
        }
        // Sleep
        if title.contains("sleep") || title.contains("rest") || title.contains("hours") {
            return "😴"
        }
        // Water/Hydration
        if title.contains("water") || title.contains("hydrat") || title.contains("drink") {
            return "💧"
        }
        // Health
        if title.contains("health") || title.contains("wellness") || title.contains("healthy") {
            return "❤️"
        }
        // Reading
        if title.contains("read") || title.contains("book") || title.contains("pages") ||
           title.contains("chapter") {
            return "📚"
        }
        // Learning
        if title.contains("learn") || title.contains("study") || title.contains("course") ||
           title.contains("class") || title.contains("skill") || title.contains("certif") {
            return "🎓"
        }
        // Coding
        if title.contains("code") || title.contains("program") || title.contains("develop") ||
           title.contains("app") || title.contains("software") || title.contains("tech") {
            return "💻"
        }
        // Language
        if title.contains("language") || title.contains("spanish") || title.contains("french") ||
           title.contains("chinese") || title.contains("english") || title.contains("german") {
            return "🗣️"
        }
        // Writing
        if title.contains("write") || title.contains("blog") || title.contains("article") ||
           title.contains("post") || title.contains("content") || title.contains("words") {
            return "✍️"
        }
        // Video
        if title.contains("video") || title.contains("youtube") || title.contains("tiktok") ||
           title.contains("film") {
            return "🎬"
        }
        // Music
        if title.contains("music") || title.contains("song") || title.contains("piano") ||
           title.contains("guitar") || title.contains("sing") {
            return "🎵"
        }
        // Art
        if title.contains("art") || title.contains("draw") || title.contains("paint") ||
           title.contains("design") || title.contains("create") {
            return "🎨"
        }
        // Photo
        if title.contains("photo") || title.contains("picture") || title.contains("camera") {
            return "📸"
        }
        // Tasks
        if title.contains("task") || title.contains("todo") || title.contains("complete") ||
           title.contains("finish") || title.contains("done") {
            return "✅"
        }
        // Habits
        if title.contains("habit") || title.contains("daily") || title.contains("streak") ||
           title.contains("consistent") || title.contains("routine") {
            return "🔥"
        }
        // Time/Focus
        if title.contains("time") || title.contains("hour") || title.contains("minute") ||
           title.contains("focus") || title.contains("pomodoro") || title.contains("productive") {
            return "⏰"
        }
        // Project/Ship
        if title.contains("project") || title.contains("ship") || title.contains("deliver") ||
           title.contains("deadline") || title.contains("feature") {
            return "🎯"
        }
        // Travel
        if title.contains("travel") || title.contains("trip") || title.contains("visit") ||
           title.contains("country") || title.contains("city") || title.contains("vacation") {
            return "✈️"
        }
        // Home
        if title.contains("home") || title.contains("house") || title.contains("apartment") ||
           title.contains("move") || title.contains("buy") {
            return "🏠"
        }
        // Saving
        if title.contains("save") || title.contains("saving") || title.contains("budget") ||
           title.contains("emergency fund") {
            return "🏦"
        }
        // Social
        if title.contains("friend") || title.contains("social") || title.contains("network") ||
           title.contains("connect") || title.contains("meet") || title.contains("outreach") {
            return "👥"
        }
        // Family
        if title.contains("family") || title.contains("kids") || title.contains("parent") {
            return "👨‍👩‍👧"
        }
        // Relationship
        if title.contains("date") || title.contains("relationship") || title.contains("love") {
            return "💕"
        }
        // Win/Success
        if title.contains("win") || title.contains("first") || title.contains("best") ||
           title.contains("top") || title.contains("champion") {
            return "🏆"
        }
        // Growth/Improve
        if title.contains("grow") || title.contains("improve") || title.contains("better") ||
           title.contains("progress") {
            return "🌱"
        }
        // Star/Success
        if title.contains("star") || title.contains("success") || title.contains("excellent") {
            return "⭐"
        }

        // Default
        return "🎯"
    }
}

// MARK: - Goal Edit Sheet

struct GoalEditSheet: View {
    let goal: Goal?
    let onSave: (String, Double, Double) -> Void
    let onDelete: (() -> Void)?
    let onDismiss: () -> Void

    @State private var title: String = ""
    @State private var currentValue: String = "0"
    @State private var targetValue: String = "100"
    @State private var selectedEmoji: String = "🎯"

    private let availableEmojis = [
        "🎯", "💪", "📚", "💰", "🏃", "🧘", "💡", "🔥",
        "⭐", "🚀", "💎", "🏆", "📈", "❤️", "🎨", "🎵",
        "✈️", "🏠", "🌱", "⏰"
    ]

    var isNewGoal: Bool { goal == nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNewGoal ? "Add Goal" : "Edit Goal")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(OmiColors.backgroundTertiary.opacity(0.5))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .background(OmiColors.backgroundTertiary)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Emoji selector (only for editing existing goals)
                    if !isNewGoal {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Icon")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(availableEmojis, id: \.self) { emoji in
                                        Button(action: { selectedEmoji = emoji }) {
                                            Text(emoji)
                                                .font(.system(size: 20))
                                                .frame(width: 40, height: 40)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(selectedEmoji == emoji
                                                            ? OmiColors.purplePrimary.opacity(0.2)
                                                            : OmiColors.backgroundTertiary.opacity(0.5))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .stroke(selectedEmoji == emoji ? OmiColors.purplePrimary : Color.clear, lineWidth: 2)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    // Title field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Goal Title")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)

                        TextField("Enter goal title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(OmiColors.backgroundTertiary.opacity(0.5))
                            )
                    }

                    // Current & Target fields
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Current")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)

                            TextField("0", text: $currentValue)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundColor(OmiColors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(OmiColors.backgroundTertiary.opacity(0.5))
                                )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Target")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)

                            TextField("100", text: $targetValue)
                                .textFieldStyle(.plain)
                                .font(.system(size: 14))
                                .foregroundColor(OmiColors.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(OmiColors.backgroundTertiary.opacity(0.5))
                                )
                        }
                    }
                }
                .padding(20)
            }

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Actions
            HStack(spacing: 12) {
                // Delete button (only for existing goals)
                if !isNewGoal, let onDelete = onDelete {
                    Button(action: {
                        onDelete()
                        onDismiss()
                    }) {
                        Text("Delete")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Cancel button
                Button(action: onDismiss) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)

                // Save button
                Button(action: {
                    let current = Double(currentValue) ?? 0
                    let target = Double(targetValue) ?? 100
                    onSave(title, current, target)
                    onDismiss()
                }) {
                    Text(isNewGoal ? "Add Goal" : "Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(OmiColors.purplePrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(title.isEmpty)
                .opacity(title.isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .frame(width: 400, height: isNewGoal ? 320 : 420)
        .background(OmiColors.backgroundSecondary)
        .onAppear {
            if let goal = goal {
                title = goal.title
                currentValue = goal.currentValue == goal.currentValue.rounded()
                    ? String(format: "%.0f", goal.currentValue)
                    : String(format: "%.1f", goal.currentValue)
                targetValue = goal.targetValue == goal.targetValue.rounded()
                    ? String(format: "%.0f", goal.targetValue)
                    : String(format: "%.1f", goal.targetValue)
            }
        }
    }
}

#Preview {
    GoalsWidget(
        goals: [],
        onCreateGoal: { _, _, _ in },
        onUpdateProgress: { _, _ in },
        onDeleteGoal: { _ in }
    )
    .frame(width: 350)
    .padding()
    .background(OmiColors.backgroundPrimary)
}
