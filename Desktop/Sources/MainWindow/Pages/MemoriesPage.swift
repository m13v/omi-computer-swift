import SwiftUI

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

struct MemoriesPage: View {
    @State private var memories: [ServerMemory] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedTags: Set<MemoryTag> = []
    @State private var showingAddMemory = false
    @State private var newMemoryText = ""
    @State private var editingMemory: ServerMemory? = nil
    @State private var editText = ""
    @State private var selectedMemory: ServerMemory? = nil

    // Undo delete state
    @State private var pendingDeleteMemory: ServerMemory? = nil
    @State private var deleteTask: Task<Void, Never>? = nil
    @State private var undoTimeRemaining: Double = 0

    private var filteredMemories: [ServerMemory] {
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
    private func tagCount(_ tag: MemoryTag) -> Int {
        memories.filter { tag.matches($0) }.count
    }

    /// Total unread tips count
    private var unreadTipsCount: Int {
        memories.filter { $0.isTip && !$0.isRead }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            // Filter bar
            filterBar

            // Content
            if isLoading && memories.isEmpty {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if memories.isEmpty {
                emptyState
            } else if filteredMemories.isEmpty {
                noResultsView
            } else {
                memoryList
            }
        }
        .background(Color.clear)
        .sheet(isPresented: $showingAddMemory) {
            addMemorySheet
        }
        .sheet(item: $editingMemory) { memory in
            editMemorySheet(memory)
        }
        .sheet(item: $selectedMemory) { memory in
            memoryDetailSheet(memory)
        }
        .overlay(alignment: .bottom) {
            undoDeleteToast
        }
        .task {
            await loadMemories()
        }
    }

    // MARK: - Undo Delete Toast

    @ViewBuilder
    private var undoDeleteToast: some View {
        if pendingDeleteMemory != nil {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textSecondary)

                Text("Memory deleted")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                // Progress indicator
                Text(String(format: "%.0fs", undoTimeRemaining))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OmiColors.textTertiary)
                    .monospacedDigit()

                Button {
                    undoDelete()
                } label: {
                    Text("Undo")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(OmiColors.purplePrimary)
                }
                .buttonStyle(.plain)

                Button {
                    // Dismiss immediately and delete now
                    confirmDelete()
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
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: pendingDeleteMemory != nil)
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
                    Text("\(memories.count) memories")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if unreadTipsCount > 0 {
                        Text("\(unreadTipsCount) new tips")
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

            Button {
                showingAddMemory = true
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
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        VStack(spacing: 12) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(OmiColors.textTertiary)

                TextField("Search memories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(OmiColors.textPrimary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
                    tagFilterButton(nil, "All", "tray.full", memories.count)

                    // Divider
                    Rectangle()
                        .fill(OmiColors.textQuaternary)
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)

                    // Tags in order: tips first, then categories, then tip subcategories
                    ForEach(MemoryTag.allCases) { tag in
                        tagFilterButton(tag, tag.displayName, tag.icon, tagCount(tag))
                    }

                    Spacer()

                    // Refresh button
                    Button {
                        Task { await loadMemories() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                            .rotationEffect(.degrees(isLoading ? 360 : 0))
                            .animation(isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoading)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func tagFilterButton(_ tag: MemoryTag?, _ title: String, _ icon: String, _ count: Int) -> some View {
        let isSelected = tag == nil ? selectedTags.isEmpty : selectedTags.contains(tag!)

        return Button {
            if tag == nil {
                // "All" clears selection
                selectedTags.removeAll()
            } else {
                // Toggle tag selection
                if selectedTags.contains(tag!) {
                    selectedTags.remove(tag!)
                } else {
                    selectedTags.insert(tag!)
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
            LazyVStack(spacing: 12) {
                ForEach(filteredMemories) { memory in
                    memoryCard(memory)
                        .onTapGesture {
                            selectedMemory = memory
                            // Auto-mark tips as read when opened
                            if memory.isTip && !memory.isRead {
                                Task { await markAsRead(memory) }
                            }
                        }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private func memoryCard(_ memory: ServerMemory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

            // Footer - all metadata in one line
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

                // Source device (Screenshot for tips, device name for transcriptions)
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

                // Source app (for tips from specific apps)
                if let sourceApp = memory.sourceApp {
                    Text("·")
                        .foregroundColor(OmiColors.textQuaternary)
                    HStack(spacing: 4) {
                        Image(systemName: "app")
                            .font(.system(size: 10))
                        Text(sourceApp)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(OmiColors.textTertiary)
                }

                // Microphone name (for desktop transcriptions only)
                if let micName = memory.inputDeviceName, memory.source == "desktop" {
                    Text("·")
                        .foregroundColor(OmiColors.textQuaternary)
                    HStack(spacing: 4) {
                        Image(systemName: "mic")
                            .font(.system(size: 10))
                        Text(micName)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(OmiColors.textTertiary)
                }

                // Confidence
                if let confidence = memory.confidenceString {
                    Text("·")
                        .foregroundColor(OmiColors.textQuaternary)
                    Text(confidence)
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textTertiary)
                }

                Spacer()

                // Date + dropdown menu
                Menu {
                    Button {
                        editingMemory = memory
                        editText = memory.content
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    Button {
                        Task { await toggleVisibility(memory) }
                    } label: {
                        Label(memory.isPublic ? "Make Private" : "Make Public",
                              systemImage: memory.isPublic ? "lock" : "globe")
                    }

                    if memory.isTip && !memory.isRead {
                        Button {
                            Task { await markAsRead(memory) }
                        } label: {
                            Label("Mark as Read", systemImage: "checkmark.circle")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task { await deleteMemory(memory) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(formatDate(memory.createdAt))
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .background(OmiColors.backgroundTertiary)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(memory.isTip && !memory.isRead ? OmiColors.warning.opacity(0.3) : Color.clear, lineWidth: 1)
        )
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
                        selectedMemory = nil
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
            }
            .padding(24)
        }
        .frame(width: 450, height: 500)
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
                showingAddMemory = true
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

            if !selectedTags.isEmpty {
                Button {
                    selectedTags.removeAll()
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
                Task { await loadMemories() }
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

            TextEditor(text: $newMemoryText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showingAddMemory = false
                    newMemoryText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Button {
                    Task { await createMemory() }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(newMemoryText.isEmpty ? OmiColors.textQuaternary : OmiColors.purplePrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(newMemoryText.isEmpty)
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

            TextEditor(text: $editText)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(OmiColors.backgroundTertiary)
                .cornerRadius(8)
                .frame(height: 150)

            HStack(spacing: 12) {
                Button("Cancel") {
                    editingMemory = nil
                    editText = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Button {
                    Task { await saveEditedMemory(memory) }
                } label: {
                    Text("Save")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(editText.isEmpty ? OmiColors.textQuaternary : OmiColors.purplePrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(editText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(OmiColors.backgroundSecondary)
    }

    // MARK: - API Actions

    private func loadMemories() async {
        isLoading = true
        errorMessage = nil

        do {
            memories = try await APIClient.shared.getMemories()
        } catch {
            errorMessage = error.localizedDescription
            logError("Failed to load memories", error: error)
        }

        isLoading = false
    }

    private func createMemory() async {
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

    private func deleteMemory(_ memory: ServerMemory) async {
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
                Task {
                    await confirmDelete()
                }
            }
        }
    }

    private func undoDelete() {
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

    private func confirmDelete() {
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

    private func saveEditedMemory(_ memory: ServerMemory) async {
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

    private func toggleVisibility(_ memory: ServerMemory) async {
        let newVisibility = memory.isPublic ? "private" : "public"
        do {
            try await APIClient.shared.updateMemoryVisibility(id: memory.id, visibility: newVisibility)
            await loadMemories()
        } catch {
            logError("Failed to update memory visibility", error: error)
        }
    }

    private func markAsRead(_ memory: ServerMemory) async {
        do {
            _ = try await APIClient.shared.updateMemoryReadStatus(id: memory.id, isRead: true, isDismissed: nil)
            await loadMemories()
        } catch {
            logError("Failed to mark memory as read", error: error)
        }
    }
}
