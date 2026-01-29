import SwiftUI

struct MemoriesPage: View {
    @State private var memories: [ServerMemory] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var selectedCategory: MemoryCategory? = nil
    @State private var showingAddMemory = false
    @State private var newMemoryText = ""
    @State private var editingMemory: ServerMemory? = nil
    @State private var editText = ""

    private var filteredMemories: [ServerMemory] {
        var result = memories

        // Filter by category
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
        }

        return result
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
        .task {
            await loadMemories()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memories")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Text("\(memories.count) memories")
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textTertiary)
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

            // Category tabs
            HStack(spacing: 8) {
                categoryTab(nil, "All")

                ForEach(MemoryCategory.allCases, id: \.self) { category in
                    categoryTab(category, category.displayName)
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
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func categoryTab(_ category: MemoryCategory?, _ title: String) -> some View {
        let isSelected = selectedCategory == category

        return Button {
            selectedCategory = category
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? OmiColors.purplePrimary : OmiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? OmiColors.purplePrimary.opacity(0.15) : Color.clear)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Memory List

    private var memoryList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(filteredMemories) { memory in
                    memoryCard(memory)
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
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            // Footer
            HStack(spacing: 12) {
                // Category badge
                HStack(spacing: 4) {
                    Image(systemName: memory.category.icon)
                        .font(.system(size: 10))
                    Text(memory.category.displayName)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(categoryColor(memory.category))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(categoryColor(memory.category).opacity(0.15))
                .cornerRadius(4)

                // Visibility badge
                if memory.isPublic {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10))
                        Text("Public")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(OmiColors.info)
                }

                Spacer()

                // Date
                Text(formatDate(memory.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)

                // Actions
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

                    Divider()

                    Button(role: .destructive) {
                        Task { await deleteMemory(memory) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding(16)
        .background(OmiColors.backgroundTertiary)
        .cornerRadius(12)
    }

    private func categoryColor(_ category: MemoryCategory) -> Color {
        switch category {
        case .system: return OmiColors.info
        case .interesting: return OmiColors.warning
        case .manual: return OmiColors.purplePrimary
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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

            Text("Your memories from conversations will appear here.\nYou can also add memories manually.")
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
        do {
            try await APIClient.shared.deleteMemory(id: memory.id)
            memories.removeAll { $0.id == memory.id }
        } catch {
            logError("Failed to delete memory", error: error)
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
}
