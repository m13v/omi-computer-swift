import SwiftUI
import AppKit

/// All available tags for filtering memories
enum MemoryTag: String, CaseIterable, Identifiable {
    // Focus tags - shown first
    case focus
    case focused
    case distracted
    // Tips tag (from advice system)
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
        case .focus: return "Focus"
        case .focused: return "Focused"
        case .distracted: return "Distracted"
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
        case .focus: return "eye"
        case .focused: return "eye.fill"
        case .distracted: return "eye.slash.fill"
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
        case .focus: return OmiColors.info
        case .focused: return Color.green
        case .distracted: return Color.orange
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
        case .focus:
            return memory.tags.contains("focus")
        case .focused:
            return memory.tags.contains("focused")
        case .distracted:
            return memory.tags.contains("distracted")
        case .tips:
            return memory.tags.contains("tips")
        case .system:
            // System memories that aren't tips or focus events
            return memory.category == .system && !memory.tags.contains("tips") && !memory.tags.contains("focus")
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
    @Published var memories: [ServerMemory] = [] {
        didSet { recomputeCaches() }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = "" {
        didSet { recomputeFilteredMemories() }
    }
    @Published var selectedTags: Set<MemoryTag> = [] {
        didSet { recomputeFilteredMemories() }
    }
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

    // Visibility toggle state
    @Published var isTogglingVisibility = false

    // MARK: - Cached Properties (avoid recomputation on every render)

    /// Cached filtered and sorted memories - only recomputed when inputs change
    @Published private(set) var filteredMemories: [ServerMemory] = []

    /// Cached tag counts - only recomputed when memories change
    @Published private(set) var tagCounts: [MemoryTag: Int] = [:]

    /// Cached unread tips count - only recomputed when memories change
    @Published private(set) var unreadTipsCount: Int = 0

    /// Count memories for a specific tag (uses cached value)
    func tagCount(_ tag: MemoryTag) -> Int {
        tagCounts[tag] ?? 0
    }

    /// Recompute all caches when memories change
    private func recomputeCaches() {
        // Compute tag counts once
        var counts: [MemoryTag: Int] = [:]
        for tag in MemoryTag.allCases {
            counts[tag] = memories.filter { tag.matches($0) }.count
        }
        tagCounts = counts

        // Compute unread tips count
        unreadTipsCount = memories.filter { $0.isTip && !$0.isRead }.count

        // Recompute filtered memories
        recomputeFilteredMemories()
    }

    /// Recompute filtered memories when search/tags change
    private func recomputeFilteredMemories() {
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

        filteredMemories = result
    }

    // MARK: - API Actions

    func loadMemories() async {
        isLoading = true
        errorMessage = nil

        do {
            // Fetch memories with reasonable limit to avoid timeout
            // TODO: Add pagination for users with many memories
            memories = try await APIClient.shared.getMemories(limit: 500)
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
        isTogglingVisibility = true
        let newVisibility = memory.isPublic ? "private" : "public"
        do {
            try await APIClient.shared.updateMemoryVisibility(id: memory.id, visibility: newVisibility)
            // Update memory in place
            if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                memories[index].visibility = newVisibility
            }
            // Update selectedMemory if it's the same memory (reassign to trigger SwiftUI update)
            if var selected = selectedMemory, selected.id == memory.id {
                selected.visibility = newVisibility
                selectedMemory = selected
            }
        } catch {
            logError("Failed to update memory visibility", error: error)
        }
        isTogglingVisibility = false
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
    @State private var showingMemoryGraph = false
    @State private var showCategoryFilter = false
    @State private var categorySearchText = ""
    @State private var pendingSelectedTags: Set<MemoryTag> = []

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
        .dismissableSheet(isPresented: $viewModel.showingAddMemory) {
            AddMemorySheet(viewModel: viewModel, onDismiss: { viewModel.showingAddMemory = false })
                .frame(width: 400)
        }
        .dismissableSheet(item: $viewModel.editingMemory) { memory in
            EditMemorySheet(memory: memory, viewModel: viewModel, onDismiss: { viewModel.editingMemory = nil })
                .frame(width: 400)
        }
        .dismissableSheet(item: $viewModel.selectedMemory) { memory in
            MemoryDetailSheet(
                memory: memory,
                viewModel: viewModel,
                categoryIcon: categoryIcon,
                categoryColor: categoryColor,
                tagColorFor: tagColorFor,
                formatDate: formatDate,
                onDismiss: { viewModel.selectedMemory = nil }
            )
            .frame(width: 450, height: 600)
        }
        .sheet(isPresented: $showingMemoryGraph) {
            MemoryGraphPage()
                .frame(minWidth: 800, minHeight: 600)
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
                        .foregroundColor(OmiColors.textPrimary)
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
                            .foregroundColor(OmiColors.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(OmiColors.backgroundTertiary)
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                // Memory Graph button
                Button {
                    showingMemoryGraph = true
                } label: {
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .help("View Memory Graph")

                Button {
                    viewModel.showingAddMemory = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Memory")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(OmiColors.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                // Refresh button
                Button {
                    Task { await viewModel.loadMemories() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(OmiColors.backgroundTertiary)
                        .cornerRadius(8)
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)
                .help("Refresh memories")

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
                        .foregroundColor(.black)
                        .frame(width: 32, height: 32)
                        .background(Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(OmiColors.border, lineWidth: 1)
                        )
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

    /// Label for the category filter button
    private var categoryFilterLabel: String {
        if viewModel.selectedTags.isEmpty {
            return "All"
        } else if viewModel.selectedTags.count == 1 {
            return viewModel.selectedTags.first!.displayName
        } else {
            return "\(viewModel.selectedTags.count) selected"
        }
    }

    /// Filtered categories based on search text
    private var filteredCategories: [MemoryTag] {
        if categorySearchText.isEmpty {
            return MemoryTag.allCases
        }
        return MemoryTag.allCases.filter { $0.displayName.localizedCaseInsensitiveContains(categorySearchText) }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
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

            // Category filter dropdown
            Button {
                pendingSelectedTags = viewModel.selectedTags
                categorySearchText = ""
                showCategoryFilter = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 12))
                    Text(categoryFilterLabel)
                        .font(.system(size: 13, weight: viewModel.selectedTags.isEmpty ? .regular : .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .foregroundColor(viewModel.selectedTags.isEmpty ? OmiColors.textSecondary : OmiColors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(viewModel.selectedTags.isEmpty ? OmiColors.backgroundTertiary : Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(viewModel.selectedTags.isEmpty ? Color.clear : OmiColors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showCategoryFilter, arrowEdge: .bottom) {
                categoryFilterPopover
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private var categoryFilterPopover: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)
                    .font(.system(size: 12))

                TextField("Search categories...", text: $categorySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textPrimary)

                if !categorySearchText.isEmpty {
                    Button {
                        categorySearchText = ""
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

            // Category list
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
                            Text("\(viewModel.memories.count)")
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

                    Divider()
                        .padding(.vertical, 4)

                    // Category items
                    ForEach(filteredCategories) { tag in
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 300)

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
                    showCategoryFilter = false
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
        .background(OmiColors.backgroundSecondary)
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
        .foregroundColor(OmiColors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(OmiColors.backgroundTertiary)
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
                .foregroundColor(OmiColors.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(OmiColors.border, lineWidth: 1)
                )
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
                        .foregroundColor(OmiColors.textSecondary)
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
                .foregroundColor(OmiColors.textPrimary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(OmiColors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sheets

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
                    .foregroundColor(OmiColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OmiColors.backgroundSecondary)
                    .cornerRadius(4)

                    if let tipCat = memory.tipCategory {
                        HStack(spacing: 4) {
                            Image(systemName: memory.tipCategoryIcon)
                                .font(.system(size: 10))
                            Text(tipCat.capitalized)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(OmiColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OmiColors.backgroundSecondary)
                        .cornerRadius(4)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: categoryIcon(memory.category))
                            .font(.system(size: 10))
                        Text(memory.category.displayName)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(OmiColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OmiColors.backgroundSecondary)
                    .cornerRadius(4)
                }

                // Source device
                if let sourceName = memory.sourceName {
                    HStack(spacing: 4) {
                        Image(systemName: memory.sourceIcon)
                            .font(.system(size: 10))
                        Text(sourceName)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(OmiColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OmiColors.backgroundSecondary)
                    .cornerRadius(4)
                }

                Spacer()

                // Date
                Text(formatDate(memory.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(OmiColors.backgroundSecondary)
                    .cornerRadius(4)

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
            // No animation wrapper - simple state update for instant response
            isHovered = hovering
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

// MARK: - Memory Detail Sheet

struct MemoryDetailSheet: View {
    let memory: ServerMemory
    @ObservedObject var viewModel: MemoriesViewModel
    let categoryIcon: (MemoryCategory) -> String
    let categoryColor: (MemoryCategory) -> Color
    let tagColorFor: (String) -> Color
    let formatDate: (Date) -> String
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var environmentDismiss

    private func dismissSheet() {
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    var body: some View {
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

                    DismissButton(action: dismissSheet)
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
                    MemoryActionRow(
                        icon: "pencil",
                        title: "Edit Memory",
                        iconColor: OmiColors.textPrimary,
                        textColor: OmiColors.textPrimary,
                        backgroundColor: OmiColors.backgroundTertiary
                    ) {
                        let memoryToEdit = memory
                        // Dismiss first, then open edit sheet after sheet animation completes
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms before dismiss
                            dismissSheet()
                            // Wait for sheet dismiss animation to complete (~300ms)
                            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms after dismiss
                            viewModel.editingMemory = memoryToEdit
                            viewModel.editText = memoryToEdit.content
                        }
                    }

                    // Visibility toggle
                    HStack {
                        Image(systemName: memory.isPublic ? "globe" : "lock")
                            .foregroundColor(memory.isPublic ? OmiColors.success : OmiColors.textTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Public")
                                .font(.system(size: 14))
                                .foregroundColor(OmiColors.textPrimary)
                            Text(memory.isPublic ? "Visible in your persona" : "Only you can see this")
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                        Spacer()
                        if viewModel.isTogglingVisibility {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Toggle("", isOn: Binding(
                                get: { memory.isPublic },
                                set: { _ in
                                    Task { await viewModel.toggleVisibility(memory) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }
                    }
                    .padding(12)
                    .background(OmiColors.backgroundTertiary)
                    .cornerRadius(8)

                    // Mark as read (for unread tips)
                    if memory.isTip && !memory.isRead {
                        MemoryActionRow(
                            icon: "checkmark.circle",
                            title: "Mark as Read",
                            iconColor: OmiColors.textPrimary,
                            textColor: OmiColors.textPrimary,
                            backgroundColor: OmiColors.backgroundTertiary
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                dismissSheet()
                                await viewModel.markAsRead(memory)
                            }
                        }
                    }

                    // View conversation (if linked)
                    if let conversationId = memory.conversationId {
                        MemoryActionRow(
                            icon: "bubble.left.and.bubble.right",
                            title: "View Source Conversation",
                            iconColor: OmiColors.textPrimary,
                            textColor: OmiColors.textPrimary,
                            backgroundColor: OmiColors.backgroundTertiary,
                            trailingIcon: "arrow.up.right"
                        ) {
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                dismissSheet()
                                await viewModel.navigateToConversation(id: conversationId)
                            }
                        }
                    }

                    // Delete button
                    MemoryActionRow(
                        icon: "trash",
                        title: "Delete Memory",
                        iconColor: OmiColors.error,
                        textColor: OmiColors.error,
                        backgroundColor: OmiColors.error.opacity(0.1)
                    ) {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            dismissSheet()
                            await viewModel.deleteMemory(memory)
                        }
                    }
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
        .frame(width: 450)
        .frame(maxHeight: 600)
        .background(OmiColors.backgroundSecondary)
    }

    private func tagBadge(_ title: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(OmiColors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(OmiColors.backgroundTertiary)
        .cornerRadius(4)
    }
}

// MARK: - Memory Action Row
/// A row button that prevents click-through when tapped, using the same pattern as SafeDismissButton.
/// Sends a synthetic mouse-up event before executing the action.
private struct MemoryActionRow: View {
    let icon: String
    let title: String
    let iconColor: Color
    let textColor: Color
    let backgroundColor: Color
    var trailingIcon: String? = nil
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(iconColor)
            Text(title)
            Spacer()
            if let trailing = trailingIcon {
                Image(systemName: trailing)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
            }
        }
        .font(.system(size: 14))
        .foregroundColor(textColor)
        .padding(12)
        .background(backgroundColor)
        .cornerRadius(8)
        .opacity(isPressed ? 0.7 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isPressed else { return } // Prevent double-tap
            isPressed = true

            log("MEMORY ACTION: \(title) tapped at mouse position: \(NSEvent.mouseLocation)")

            // Consume the click by resigning first responder
            NSApp.keyWindow?.makeFirstResponder(nil)

            // Post a mouse-up event to ensure any pending click is consumed
            if let window = NSApp.keyWindow {
                let event = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: window.mouseLocationOutsideOfEventStream,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 1,
                    pressure: 0
                )
                if let event = event {
                    window.sendEvent(event)
                    log("MEMORY ACTION: Sent synthetic mouse-up event for \(title)")
                }
            }

            // Execute the action (which should handle its own delays for dismiss)
            action()
        }
    }
}

// MARK: - Add Memory Sheet

struct AddMemorySheet: View {
    @ObservedObject var viewModel: MemoriesViewModel
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var environmentDismiss

    private func dismissSheet() {
        viewModel.newMemoryText = ""
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header with close button
            HStack {
                Text("Add Memory")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                DismissButton(action: dismissSheet)
            }

            TextEditor(text: $viewModel.newMemoryText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                // Cancel button
                Button(action: dismissSheet) {
                    Text("Cancel")
                        .foregroundColor(OmiColors.textSecondary)
                }

                Spacer()

                Button {
                    Task { await viewModel.createMemory() }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.newMemoryText.isEmpty ? OmiColors.textTertiary : OmiColors.textPrimary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(viewModel.newMemoryText.isEmpty ? OmiColors.backgroundTertiary : Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.newMemoryText.isEmpty ? Color.clear : OmiColors.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.newMemoryText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(OmiColors.backgroundSecondary)
    }
}

// MARK: - Edit Memory Sheet

struct EditMemorySheet: View {
    let memory: ServerMemory
    @ObservedObject var viewModel: MemoriesViewModel
    var onDismiss: (() -> Void)? = nil

    @Environment(\.dismiss) private var environmentDismiss

    private func dismissSheet() {
        viewModel.editText = ""
        if let onDismiss = onDismiss {
            onDismiss()
        } else {
            environmentDismiss()
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header with close button
            HStack {
                Text("Edit Memory")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)
                Spacer()
                DismissButton(action: dismissSheet)
            }

            TextEditor(text: $viewModel.editText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                // Cancel button
                Button(action: dismissSheet) {
                    Text("Cancel")
                        .foregroundColor(OmiColors.textSecondary)
                }

                Spacer()

                Button {
                    Task { await viewModel.saveEditedMemory(memory) }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(viewModel.editText.isEmpty ? OmiColors.textTertiary : OmiColors.textPrimary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(viewModel.editText.isEmpty ? OmiColors.backgroundTertiary : Color.white)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(viewModel.editText.isEmpty ? Color.clear : OmiColors.border, lineWidth: 1)
                        )
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
