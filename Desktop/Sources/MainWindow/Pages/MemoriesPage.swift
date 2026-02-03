import SwiftUI
import AppKit

/// All available tags for filtering memories
enum MemoryTag: String, CaseIterable, Identifiable {
    // Tips tag (from advice system) - shown first
    case tips
    // Memory categories
    case system
    case interesting
    case manual
    // Tip subcategories (from advice system)
    case productivity
    case health
    case communication
    case learning
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tips: return "Tips"
        case .system: return "System"
        case .interesting: return "Interesting"
        case .manual: return "Manual"
        case .productivity: return "Productivity"
        case .health: return "Health"
        case .communication: return "Communication"
        case .learning: return "Learning"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .tips: return "lightbulb.fill"
        case .system: return "gearshape"
        case .interesting: return "sparkles"
        case .manual: return "square.and.pencil"
        case .productivity: return "chart.line.uptrend.xyaxis"
        case .health: return "heart.fill"
        case .communication: return "bubble.left.and.bubble.right.fill"
        case .learning: return "book.fill"
        case .other: return "ellipsis.circle"
        }
    }

    var color: Color {
        switch self {
        case .tips: return OmiColors.warning
        case .system: return OmiColors.info
        case .interesting: return OmiColors.warning
        case .manual: return OmiColors.purplePrimary
        case .productivity: return OmiColors.info
        case .health: return OmiColors.error
        case .communication: return OmiColors.success
        case .learning: return OmiColors.purplePrimary
        case .other: return OmiColors.textTertiary
        }
    }

    /// Check if a memory matches this tag
    func matches(_ memory: ServerMemory) -> Bool {
        switch self {
        case .tips:
            return memory.tags.contains("tips")
        case .system:
            return memory.category == .system && !memory.tags.contains("tips")
        case .interesting:
            return memory.category == .interesting && !memory.tags.contains("tips")
        case .manual:
            return memory.category == .manual && !memory.tags.contains("tips")
        case .productivity, .health, .communication, .learning, .other:
            return memory.tags.contains(rawValue)
        }
    }
}

// MARK: - Memories View Model

@MainActor
class MemoriesViewModel: ObservableObject {
    @Published var memories: [ServerMemory] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedTags: Set<MemoryTag> = []
    @Published var showingAddMemory = false
    @Published var newMemoryText = ""
    @Published var editingMemory: ServerMemory? = nil
    @Published var editText = ""
    @Published var selectedMemory: ServerMemory? = nil

    // Undo delete state
    @Published var pendingDeleteMemory: ServerMemory? = nil
    @Published var undoTimeRemaining: Double = 0
    private var deleteTask: Task<Void, Never>? = nil

    // Bulk operations state
    @Published var showingDeleteAllConfirmation = false
    @Published var isBulkOperationInProgress = false

    // Conversation linking state
    @Published var linkedConversation: ServerConversation? = nil
    @Published var isLoadingConversation = false

    var filteredMemories: [ServerMemory] {
        var result = memories

        // Filter by selected tags (OR logic - match any selected tag)
        if !selectedTags.isEmpty {
            result = result.filter { memory in
                selectedTags.contains { tag in tag.matches(memory) }
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
        }

        // Sort by date (newest first)
        result.sort { $0.createdAt > $1.createdAt }

        return result
    }

    /// Count memories for a specific tag
    func tagCount(_ tag: MemoryTag) -> Int {
        memories.filter { tag.matches($0) }.count
    }

    /// Total unread tips count
    var unreadTipsCount: Int {
        memories.filter { $0.isTip && !$0.isRead }.count
    }

    // MARK: - API Actions

    func loadMemories() async {
        isLoading = true
        errorMessage = nil

        do {
            // Use high limit to fetch all memories (rejected memories are filtered server-side
            // but the filter happens after the Firestore limit, so we need a high limit)
            memories = try await APIClient.shared.getMemories(limit: 10000)
        } catch {
            errorMessage = error.localizedDescription
            logError("Failed to load memories", error: error)
        }

        isLoading = false
    }

    func createMemory() async {
        guard !newMemoryText.isEmpty else { return }

        do {
            _ = try await APIClient.shared.createMemory(content: newMemoryText)
            showingAddMemory = false
            newMemoryText = ""
            await loadMemories()
        } catch {
            logError("Failed to create memory", error: error)
        }
    }

    func deleteMemory(_ memory: ServerMemory) async {
        // Cancel any existing pending delete
        deleteTask?.cancel()
        if let existingPending = pendingDeleteMemory {
            // Immediately delete the previous pending memory
            await performActualDelete(existingPending)
        }

        // Remove from UI immediately (optimistic)
        withAnimation(.easeInOut(duration: 0.2)) {
            memories.removeAll { $0.id == memory.id }
            pendingDeleteMemory = memory
            undoTimeRemaining = 4
        }

        // Start countdown timer
        deleteTask = Task {
            // Update countdown every 100ms
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if Task.isCancelled { return }
                await MainActor.run {
                    undoTimeRemaining = max(0, undoTimeRemaining - 0.1)
                }
            }

            if Task.isCancelled { return }

            // Timer expired, perform actual delete
            await MainActor.run {
                confirmDelete()
            }
        }
    }

    func undoDelete() {
        guard let memory = pendingDeleteMemory else { return }

        // Cancel the delete timer
        deleteTask?.cancel()
        deleteTask = nil

        // Restore the memory to the list
        withAnimation(.easeInOut(duration: 0.2)) {
            memories.append(memory)
            memories.sort { $0.createdAt > $1.createdAt }
            pendingDeleteMemory = nil
            undoTimeRemaining = 0
        }
    }

    func confirmDelete() {
        guard let memory = pendingDeleteMemory else { return }

        // Cancel timer if still running
        deleteTask?.cancel()
        deleteTask = nil

        Task {
            await performActualDelete(memory)
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            pendingDeleteMemory = nil
            undoTimeRemaining = 0
        }
    }

    private func performActualDelete(_ memory: ServerMemory) async {
        do {
            try await APIClient.shared.deleteMemory(id: memory.id)
            AnalyticsManager.shared.memoryDeleted(conversationId: memory.id)
        } catch {
            logError("Failed to delete memory", error: error)
            // Restore on failure
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if !memories.contains(where: { $0.id == memory.id }) {
                        memories.append(memory)
                        memories.sort { $0.createdAt > $1.createdAt }
                    }
                }
            }
        }
    }

    func saveEditedMemory(_ memory: ServerMemory) async {
        guard !editText.isEmpty else { return }

        do {
            try await APIClient.shared.editMemory(id: memory.id, content: editText)
            editingMemory = nil
            editText = ""
            await loadMemories()
        } catch {
            logError("Failed to edit memory", error: error)
        }
    }

    func toggleVisibility(_ memory: ServerMemory) async {
        let newVisibility = memory.isPublic ? "private" : "public"
        do {
            try await APIClient.shared.updateMemoryVisibility(id: memory.id, visibility: newVisibility)
            await loadMemories()
        } catch {
            logError("Failed to update memory visibility", error: error)
        }
    }

    func markAsRead(_ memory: ServerMemory) async {
        do {
            _ = try await APIClient.shared.updateMemoryReadStatus(id: memory.id, isRead: true, isDismissed: nil)
            await loadMemories()
        } catch {
            logError("Failed to mark memory as read", error: error)
        }
    }

    // MARK: - Bulk Operations

    func makeAllMemoriesPrivate() async {
        isBulkOperationInProgress = true
        do {
            try await APIClient.shared.updateAllMemoriesVisibility(visibility: "private")
            await loadMemories()
        } catch {
            logError("Failed to make all memories private", error: error)
        }
        isBulkOperationInProgress = false
    }

    func makeAllMemoriesPublic() async {
        isBulkOperationInProgress = true
        do {
            try await APIClient.shared.updateAllMemoriesVisibility(visibility: "public")
            await loadMemories()
        } catch {
            logError("Failed to make all memories public", error: error)
        }
        isBulkOperationInProgress = false
    }

    func deleteAllMemories() async {
        isBulkOperationInProgress = true

        // Cancel any pending single delete
        deleteTask?.cancel()
        pendingDeleteMemory = nil

        do {
            try await APIClient.shared.deleteAllMemories()
            withAnimation(.easeInOut(duration: 0.3)) {
                memories.removeAll()
            }
        } catch {
            logError("Failed to delete all memories", error: error)
            // Reload to restore state
            await loadMemories()
        }
        isBulkOperationInProgress = false
    }

    // MARK: - Conversation Linking

    func navigateToConversation(id: String) async {
        isLoadingConversation = true
        do {
            linkedConversation = try await APIClient.shared.getConversation(id: id)
        } catch {
            logError("Failed to load conversation", error: error)
        }
        isLoadingConversation = false
    }

    func dismissConversation() {
        linkedConversation = nil
    }
}

// MARK: - Memories Page

struct MemoriesPage: View {
    @ObservedObject var viewModel: MemoriesViewModel

    var body: some View {
        Group {
            if let conversation = viewModel.linkedConversation {
                // Show conversation detail view
                ConversationDetailView(
                    conversation: conversation,
                    onBack: { viewModel.dismissConversation() }
                )
            } else {
                // Main memories view
                mainMemoriesView
            }
        }
    }

    private var mainMemoriesView: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Filter bar
            filterBar

            // Content
            if viewModel.isLoading && viewModel.memories.isEmpty {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.memories.isEmpty {
                emptyState
            } else if viewModel.filteredMemories.isEmpty {
                noResultsView
            } else {
                memoryList
            }
        }
        .background(Color.clear)
        .sheet(isPresented: $viewModel.showingAddMemory) {
            addMemorySheet
        }
        .sheet(item: $viewModel.editingMemory) { memory in
            editMemorySheet(memory)
        }
        .sheet(item: $viewModel.selectedMemory) { memory in
            memoryDetailSheet(memory)
        }
        .overlay(alignment: .bottom) {
            undoDeleteToast
        }
        .overlay {
            // Loading overlay for conversation fetch
            if viewModel.isLoadingConversation {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                    }
            }
        }
    }

    // MARK: - Undo Delete Toast

    @ViewBuilder
    private var undoDeleteToast: some View {
        if viewModel.pendingDeleteMemory != nil {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textSecondary)

                Text("Memory deleted")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                // Progress indicator
                Text(String(format: "%.0fs", viewModel.undoTimeRemaining))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OmiColors.textTertiary)
                    .monospacedDigit()

                Button {
                    viewModel.undoDelete()
                } label: {
                    Text("Undo")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OmiColors.purplePrimary)
                }
                .buttonStyle(.plain)

                Button {
                    // Dismiss immediately and delete now
                    viewModel.confirmDelete()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(OmiColors.textQuaternary.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.pendingDeleteMemory != nil)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memories")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                HStack(spacing: 8) {
                    Text("\(viewModel.memories.count) memories")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if viewModel.unreadTipsCount > 0 {
                        Text("\(viewModel.unreadTipsCount) new tips")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.warning)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(OmiColors.warning.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    viewModel.showingAddMemory = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Memory")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(OmiColors.purplePrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Management menu
                Menu {
                    Section("Visibility") {
                        Button {
                            Task { await viewModel.makeAllMemoriesPrivate() }
                        } label: {
                            Label("Make All Private", systemImage: "lock")
                        }
                        .disabled(viewModel.memories.isEmpty || viewModel.isBulkOperationInProgress)

                        Button {
                            Task { await viewModel.makeAllMemoriesPublic() }
                        } label: {
                            Label("Make All Public", systemImage: "globe")
                        }
                        .disabled(viewModel.memories.isEmpty || viewModel.isBulkOperationInProgress)
                    }

                    Divider()

                    Section {
                        Button(role: .destructive) {
                            viewModel.showingDeleteAllConfirmation = true
                        } label: {
                            Label("Delete All Memories", systemImage: "trash")
                        }
                        .disabled(viewModel.memories.isEmpty || viewModel.isBulkOperationInProgress)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(8)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .alert("Delete All Memories?", isPresented: $viewModel.showingDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                Task { await viewModel.deleteAllMemories() }
            }
        } message: {
            Text("This will permanently delete all \(viewModel.memories.count) memories. This action cannot be undone.")
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 12) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)

                TextField("Search memories...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(OmiColors.textPrimary)

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(8)

            // Tag filters (multi-select)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // All button
                    tagFilterButton(nil, "All", "tray.full", viewModel.memories.count)

                    // Divider
                    Rectangle()
                        .fill(OmiColors.textQuaternary)
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)

                    // Tags in order: tips first, then categories, then tip subcategories
                    ForEach(MemoryTag.allCases) { tag in
                        tagFilterButton(tag, tag.displayName, tag.icon, viewModel.tagCount(tag))
                    }

                    Spacer()

                    // Refresh button
                    Button {
                        Task { await viewModel.loadMemories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                            .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                            .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func tagFilterButton(_ tag: MemoryTag?, _ title: String, _ icon: String, _ count: Int) -> some View {
        let isSelected = tag == nil ? viewModel.selectedTags.isEmpty : viewModel.selectedTags.contains(tag!)

        return Button {
            if tag == nil {
                // "All" clears selection
                viewModel.selectedTags.removeAll()
            } else {
                // Toggle tag selection
                if viewModel.selectedTags.contains(tag!) {
                    viewModel.selectedTags.remove(tag!)
                } else {
                    viewModel.selectedTags.insert(tag!)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? (tag?.color ?? OmiColors.purplePrimary) : OmiColors.textTertiary)

                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? (tag?.color ?? OmiColors.purplePrimary) : OmiColors.textSecondary)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isSelected ? (tag?.color ?? OmiColors.purplePrimary) : OmiColors.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? (tag?.color ?? OmiColors.purplePrimary).opacity(0.15) : OmiColors.backgroundTertiary)
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? (tag?.color ?? OmiColors.purplePrimary).opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? (tag?.color ?? OmiColors.purplePrimary).opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Memory List

    private var memoryList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredMemories) { memory in
                    MemoryCardView(
                        memory: memory,
                        onTap: {
                            viewModel.selectedMemory = memory
                            // Auto-mark tips as read when opened
                            if memory.isTip && !memory.isRead {
                                Task { await viewModel.markAsRead(memory) }
                            }
                        },
                        categoryIcon: categoryIcon,
                        categoryColor: categoryColor,
                        tagColorFor: tagColorFor,
                        formatDate: formatDate
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func tagBadge(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .cornerRadius(4)
    }

    private func categoryIcon(_ category: MemoryCategory) -> String {
        switch category {
        case .system: return "gearshape"
        case .interesting: return "sparkles"
        case .manual: return "square.and.pencil"
        }
    }

    private func categoryColor(_ category: MemoryCategory) -> Color {
        switch category {
        case .system: return OmiColors.info
        case .interesting: return OmiColors.warning
        case .manual: return OmiColors.purplePrimary
        }
    }

    private func tagColorFor(_ tag: String) -> Color {
        switch tag {
        case "productivity": return OmiColors.info
        case "health": return OmiColors.error
        case "communication": return OmiColors.success
        case "learning": return OmiColors.purplePrimary
        case "other": return OmiColors.textTertiary
        default: return OmiColors.textTertiary
        }
    }

    private func formatDate(_ date: Date) -> String {
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.unitsStyle = .abbreviated
        let relativeTime = relativeFormatter.localizedString(for: date, relativeTo: Date())

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, h:mm a"
        let absoluteTime = dateFormatter.string(from: date)

        return "\(relativeTime) · \(absoluteTime)"
    }

    // MARK: - Detail Sheet

    private func memoryDetailSheet(_ memory: ServerMemory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with tags
                HStack(spacing: 8) {
                    if memory.isTip {
                        tagBadge("Tips", "lightbulb.fill", OmiColors.warning)
                        if let tipCat = memory.tipCategory {
                            tagBadge(tipCat.capitalized, memory.tipCategoryIcon, tagColorFor(tipCat))
                        }
                    } else {
                        tagBadge(memory.category.displayName, categoryIcon(memory.category), categoryColor(memory.category))
                    }

                    Spacer()

                    Button {
                        viewModel.selectedMemory = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                // Content
                Text(memory.content)
                    .font(.system(size: 15))
                    .foregroundColor(OmiColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // Reasoning
                if let reasoning = memory.reasoning, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Why this tip?")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OmiColors.textSecondary)

                        Text(reasoning)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textPrimary)
                    }
                    .padding(12)
                    .background(OmiColors.backgroundTertiary)
                    .cornerRadius(8)
                }

                // Context
                if memory.currentActivity != nil || memory.contextSummary != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OmiColors.textSecondary)

                        if let activity = memory.currentActivity {
                            HStack(spacing: 6) {
                                Image(systemName: "figure.walk")
                                    .font(.system(size: 12))
                                Text(activity)
                                    .font(.system(size: 13))
                            }
                            .foregroundColor(OmiColors.textTertiary)
                        }

                        if let context = memory.contextSummary {
                            Text(context)
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }
                    .padding(12)
                    .background(OmiColors.backgroundTertiary)
                    .cornerRadius(8)
                }

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    if let confidence = memory.confidenceString {
                        HStack {
                            Text("Confidence")
                                .foregroundColor(OmiColors.textSecondary)
                            Spacer()
                            Text(confidence)
                                .foregroundColor(OmiColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }

                    if let sourceApp = memory.sourceApp {
                        HStack {
                            Text("Source App")
                                .foregroundColor(OmiColors.textSecondary)
                            Spacer()
                            Text(sourceApp)
                                .foregroundColor(OmiColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }

                    if let sourceName = memory.sourceName {
                        HStack {
                            Text("Device")
                                .foregroundColor(OmiColors.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: memory.sourceIcon)
                                Text(sourceName)
                            }
                            .foregroundColor(OmiColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }

                    if let micName = memory.inputDeviceName, memory.source == "desktop" {
                        HStack {
                            Text("Microphone")
                                .foregroundColor(OmiColors.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "mic")
                                Text(micName)
                            }
                            .foregroundColor(OmiColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }

                    HStack {
                        Text("Created")
                            .foregroundColor(OmiColors.textSecondary)
                        Spacer()
                        Text(formatDate(memory.createdAt))
                            .foregroundColor(OmiColors.textPrimary)
                    }
                    .font(.system(size: 13))
                }
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)

                // Action Buttons
                VStack(spacing: 10) {
                    // Edit button
                    Button {
                        viewModel.selectedMemory = nil
                        viewModel.editingMemory = memory
                        viewModel.editText = memory.content
                    } label: {
                        HStack {
                            Image(systemName: "pencil")
                            Text("Edit Memory")
                            Spacer()
                        }
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textPrimary)
                        .padding(12)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Visibility toggle
                    Button {
                        Task {
                            await viewModel.toggleVisibility(memory)
                            viewModel.selectedMemory = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: memory.isPublic ? "lock" : "globe")
                            Text(memory.isPublic ? "Make Private" : "Make Public")
                            Spacer()
                        }
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textPrimary)
                        .padding(12)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    // Mark as read (for unread tips)
                    if memory.isTip && !memory.isRead {
                        Button {
                            Task {
                                await viewModel.markAsRead(memory)
                                viewModel.selectedMemory = nil
                            }
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                Text("Mark as Read")
                                Spacer()
                            }
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textPrimary)
                            .padding(12)
                            .background(OmiColors.backgroundTertiary)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    // View conversation (if linked)
                    if let conversationId = memory.conversationId {
                        Button {
                            viewModel.selectedMemory = nil
                            Task { await viewModel.navigateToConversation(id: conversationId) }
                        } label: {
                            HStack {
                                Image(systemName: "bubble.left.and.bubble.right")
                                Text("View Source Conversation")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textPrimary)
                            .padding(12)
                            .background(OmiColors.backgroundTertiary)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    // Delete button
                    Button {
                        viewModel.selectedMemory = nil
                        Task { await viewModel.deleteMemory(memory) }
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Memory")
                            Spacer()
                        }
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.error)
                        .padding(12)
                        .background(OmiColors.error.opacity(0.1))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .frame(width: 450)
        .frame(maxHeight: 600)
        .background(OmiColors.backgroundSecondary)
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text("No Memories Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Your memories and tips will appear here.\nMemories are extracted from your conversations.")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.showingAddMemory = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                    Text("Add Your First Memory")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(OmiColors.purplePrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(OmiColors.textTertiary)

            Text("No Results")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Try a different search or filter")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)

            if !viewModel.selectedTags.isEmpty {
                Button {
                    viewModel.selectedTags.removeAll()
                } label: {
                    Text("Clear Filters")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OmiColors.purplePrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)

            Text("Loading memories...")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(OmiColors.error)

            Text("Failed to Load Memories")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)

            Button {
                Task { await viewModel.loadMemories() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(OmiColors.purplePrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sheets

    private var addMemorySheet: some View {
        VStack(spacing: 20) {
            Text("Add Memory")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            TextEditor(text: $viewModel.newMemoryText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.showingAddMemory = false
                    viewModel.newMemoryText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Button {
                    Task { await viewModel.createMemory() }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(viewModel.newMemoryText.isEmpty ? OmiColors.textQuaternary : OmiColors.purplePrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.newMemoryText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(OmiColors.backgroundSecondary)
    }

    private func editMemorySheet(_ memory: ServerMemory) -> some View {
        VStack(spacing: 20) {
            Text("Edit Memory")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            TextEditor(text: $viewModel.editText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                Button("Cancel") {
                    viewModel.editingMemory = nil
                    viewModel.editText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Button {
                    Task { await viewModel.saveEditedMemory(memory) }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(viewModel.editText.isEmpty ? OmiColors.textQuaternary : OmiColors.purplePrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.editText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(OmiColors.backgroundSecondary)
    }
}

// MARK: - Memory Card View

private struct MemoryCardView: View {
    let memory: ServerMemory
    let onTap: () -> Void
    let categoryIcon: (MemoryCategory) -> String
    let categoryColor: (MemoryCategory) -> Color
    let tagColorFor: (String) -> Color
    let formatDate: (Date) -> String

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Content
            Text(memory.content)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            // Reasoning (for tips)
            if let reasoning = memory.reasoning, !reasoning.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10))
                        .foregroundColor(OmiColors.textQuaternary)
                    Text(reasoning)
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(OmiColors.backgroundSecondary)
                .cornerRadius(6)
            }

            // Footer - metadata
            HStack(spacing: 6) {
                // Unread indicator
                if memory.isTip && !memory.isRead {
                    Circle()
                        .fill(OmiColors.warning)
                        .frame(width: 6, height: 6)
                }

                // Category/Tags
                if memory.isTip {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                        Text("Tips")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(OmiColors.warning)

                    if let tipCat = memory.tipCategory {
                        Text("·")
                            .foregroundColor(OmiColors.textQuaternary)
                        HStack(spacing: 4) {
                            Image(systemName: memory.tipCategoryIcon)
                                .font(.system(size: 10))
                            Text(tipCat.capitalized)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(tagColorFor(tipCat))
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: categoryIcon(memory.category))
                            .font(.system(size: 10))
                        Text(memory.category.displayName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(categoryColor(memory.category))
                }

                // Source device
                if let sourceName = memory.sourceName {
                    Text("·")
                        .foregroundColor(OmiColors.textQuaternary)
                    HStack(spacing: 4) {
                        Image(systemName: memory.sourceIcon)
                            .font(.system(size: 10))
                        Text(sourceName)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(OmiColors.textTertiary)
                }

                Spacer()

                // Date
                Text(formatDate(memory.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)

                // Click hint on hover
                if isHovered {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovered ? OmiColors.backgroundSecondary : OmiColors.backgroundTertiary)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(memory.isTip && !memory.isRead ? OmiColors.warning.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            // Change cursor to pointing hand on hover
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            onTap()
        }
    }
}
