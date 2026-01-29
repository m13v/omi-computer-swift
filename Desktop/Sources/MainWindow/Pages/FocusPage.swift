import SwiftUI

// MARK: - Focus View Model

@MainActor
class FocusViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var showHistorical = false

    private let storage = FocusStorage.shared
    private let settings = FocusAssistantSettings.shared

    var filteredSessions: [StoredFocusSession] {
        let base = showHistorical ? storage.sessions : storage.todaySessions

        guard !searchText.isEmpty else { return base }

        return base.filter {
            $0.appOrSite.localizedCaseInsensitiveContains(searchText) ||
            $0.description.localizedCaseInsensitiveContains(searchText) ||
            ($0.message?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var currentStatus: FocusStatus? {
        storage.currentStatus
    }

    var currentApp: String? {
        storage.currentApp
    }

    var stats: FocusDayStats {
        storage.todayStats
    }

    var isMonitoring: Bool {
        settings.isEnabled
    }

    var todayCount: Int {
        storage.todaySessions.count
    }

    func deleteSession(_ id: String) {
        storage.deleteSession(id)
        objectWillChange.send()
    }

    func clearAll() {
        storage.clearAll()
        objectWillChange.send()
    }

    func refresh() async {
        await storage.refreshFromBackend()
        await MainActor.run {
            objectWillChange.send()
        }
    }
}

// MARK: - Focus Page

struct FocusPage: View {
    @StateObject private var viewModel = FocusViewModel()
    @ObservedObject private var storage = FocusStorage.shared
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            ScrollView {
                VStack(spacing: 20) {
                    // Current status banner
                    if let status = viewModel.currentStatus {
                        currentStatusBanner(status)
                    }

                    // Today's summary stats
                    statsSection

                    // Top distractions (if any)
                    if !viewModel.stats.topDistractions.isEmpty {
                        topDistractionsSection
                    }

                    // Session history
                    historySection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(Color.clear)
        .confirmationDialog(
            "Clear All History",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                viewModel.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to clear all focus history? This cannot be undone.")
        }
        .task {
            await viewModel.refresh()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Focus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                HStack(spacing: 8) {
                    // Monitoring status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.isMonitoring ? Color.green : OmiColors.textTertiary)
                            .frame(width: 8, height: 8)

                        Text(viewModel.isMonitoring ? "Monitoring" : "Not monitoring")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Text("\(viewModel.todayCount) sessions today")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 12) {
                // Toggle historical view
                Toggle(isOn: $viewModel.showHistorical) {
                    Text("Show all")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Menu {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear All History", systemImage: "trash")
                    }
                    .disabled(storage.sessions.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18))
                        .foregroundColor(OmiColors.textSecondary)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Current Status Banner

    private func currentStatusBanner(_ status: FocusStatus) -> some View {
        HStack(spacing: 16) {
            // Status icon
            ZStack {
                Circle()
                    .fill(status == .focused ? Color.green.opacity(0.2) : Color.orange.opacity(0.2))
                    .frame(width: 56, height: 56)

                Image(systemName: status == .focused ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 24))
                    .foregroundColor(status == .focused ? Color.green : Color.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(status == .focused ? "Focused" : "Distracted")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                if let app = viewModel.currentApp {
                    Text(app)
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textSecondary)
                }
            }

            Spacer()

            // Subtle pulse animation for focused state
            if status == .focused {
                Circle()
                    .fill(Color.green)
                    .frame(width: 12, height: 12)
                    .opacity(0.8)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(status == .focused
                      ? Color.green.opacity(0.08)
                      : Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(status == .focused
                                ? Color.green.opacity(0.2)
                                : Color.orange.opacity(0.2),
                                lineWidth: 1)
                )
        )
    }

    // MARK: - Stats Section

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Summary")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)
                .textCase(.uppercase)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                statCard(
                    title: "Focus Time",
                    value: "\(viewModel.stats.focusedMinutes)",
                    unit: "min",
                    icon: "eye.fill",
                    color: Color.green
                )

                statCard(
                    title: "Distracted",
                    value: "\(viewModel.stats.distractedMinutes)",
                    unit: "min",
                    icon: "eye.slash.fill",
                    color: Color.orange
                )

                statCard(
                    title: "Focus Rate",
                    value: String(format: "%.0f", viewModel.stats.focusRate),
                    unit: "%",
                    icon: "chart.pie.fill",
                    color: OmiColors.purplePrimary
                )

                statCard(
                    title: "Sessions",
                    value: "\(viewModel.stats.sessionCount)",
                    unit: "",
                    icon: "clock.fill",
                    color: OmiColors.info
                )
            }
        }
    }

    private func statCard(title: String, value: String, unit: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(color)

                Spacer()
            }

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(OmiColors.textPrimary)

                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textTertiary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(OmiColors.backgroundTertiary.opacity(0.6))
        )
    }

    // MARK: - Top Distractions

    private var topDistractionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Distractions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)
                .textCase(.uppercase)

            VStack(spacing: 8) {
                ForEach(viewModel.stats.topDistractions.prefix(5), id: \.appOrSite) { entry in
                    HStack {
                        Image(systemName: "app.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Color.orange)
                            .frame(width: 24)

                        Text(entry.appOrSite)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Text("\(entry.count)x")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)

                        Text(formatDuration(entry.totalSeconds))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OmiColors.backgroundTertiary.opacity(0.4))
                    )
                }
            }
        }
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.showHistorical ? "All Sessions" : "Today's Sessions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)
                    .textCase(.uppercase)

                Spacer()

                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(OmiColors.textTertiary)
                        .font(.system(size: 12))

                    TextField("Search...", text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                        .foregroundColor(OmiColors.textPrimary)
                        .font(.system(size: 13))

                    if !viewModel.searchText.isEmpty {
                        Button {
                            viewModel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(OmiColors.textTertiary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(6)
                .frame(width: 180)
            }

            if viewModel.filteredSessions.isEmpty {
                emptyHistoryView
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredSessions) { session in
                        SessionRow(
                            session: session,
                            onDelete: { viewModel.deleteSession(session.id) }
                        )
                    }
                }
            }
        }
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye.fill")
                .font(.system(size: 36))
                .foregroundColor(OmiColors.textTertiary)

            Text("No Sessions Yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Focus sessions will appear here as you work.\nMake sure Focus monitoring is enabled in Settings.")
                .font(.system(size: 13))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return "\(hours)h \(remainingMinutes)m"
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: StoredFocusSession
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(session.status == .focused ? Color.green : Color.orange)
                .frame(width: 10, height: 10)

            // App/site
            Text(session.appOrSite)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            // Description
            Text(session.description)
                .font(.system(size: 13))
                .foregroundColor(OmiColors.textSecondary)
                .lineLimit(1)

            Spacer()

            // Message (if any)
            if let message = session.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            // Sync status
            if !session.isSynced {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)
                    .help("Pending sync")
            }

            // Time
            Text(formatTime(session.createdAt))
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textTertiary)
                .frame(width: 60, alignment: .trailing)

            // Delete button (on hover)
            if isHovering {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? OmiColors.backgroundTertiary : OmiColors.backgroundTertiary.opacity(0.4))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .confirmationDialog(
            "Delete Session",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this session?")
        }
    }

    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d h:mm a"
            return formatter.string(from: date)
        }
    }
}

#Preview {
    FocusPage()
        .frame(width: 800, height: 600)
        .background(OmiColors.backgroundPrimary)
}
