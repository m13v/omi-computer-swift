import SwiftUI
import Combine

// MARK: - Search Debouncer

/// Debounces search queries to avoid excessive API calls
class SearchDebouncer: ObservableObject {
    /// The input query (set immediately when user types)
    @Published var inputQuery: String = ""
    /// The debounced query (updated 500ms after user stops typing)
    @Published var debouncedQuery: String = ""
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe input and debounce to output
        $inputQuery
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] value in
                self?.debouncedQuery = value
            }
            .store(in: &cancellables)
    }
}

// MARK: - Conversations Page

struct ConversationsPage: View {
    @ObservedObject var appState: AppState
    @State private var selectedConversation: ServerConversation? = nil

    // Transcript visibility state - hidden by default
    @State private var isTranscriptCollapsed: Bool = true

    // Success state after finishing conversation
    @State private var showSavedSuccess: Bool = false

    // Search state
    @State private var searchQuery: String = ""
    @State private var searchResults: [ServerConversation] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @StateObject private var searchDebouncer = SearchDebouncer()

    // Date picker state
    @State private var showDatePicker: Bool = false

    // Folder picker state
    @State private var showFolderPicker: Bool = false

    var body: some View {
        Group {
            if let selected = selectedConversation {
                // Detail view for selected conversation
                ConversationDetailView(
                    conversation: selected,
                    onBack: { selectedConversation = nil }
                )
            } else {
                // Main view with recording header and conversation list
                mainConversationsView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            // Load conversations when view appears
            if appState.conversations.isEmpty {
                Task {
                    await appState.loadConversations()
                }
            }
            // Load folders
            if appState.folders.isEmpty {
                Task {
                    await appState.loadFolders()
                }
            }
        }
    }

    // MARK: - Main View with Recording Header + List

    private var mainConversationsView: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Recording header (always visible)
                recordingHeader
                    .padding(16)

                Divider()
                    .background(OmiColors.backgroundTertiary)

                // When transcribing and expanded: full-page transcript
                // When transcribing and collapsed: show splitter then conversation list
                // When not transcribing: just conversation list
                if appState.isTranscribing && !isTranscriptCollapsed {
                    // Expanded: full-page transcript with back button
                    fullPageTranscriptView
                } else {
                    // Collapsed or not recording: show conversation list
                    conversationListSection
                }
            }

            // Toast banner for discarded/error feedback
            if showDiscarded || showError {
                toastBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 60)
            }
        }
    }

    private var toastBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: showDiscarded ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 14))

            Text(showDiscarded ? "Conversation was too short and was discarded" : "Failed to save: \(errorMessage)")
                .font(.system(size: 13))

            Spacer()
        }
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(showDiscarded ? OmiColors.warning : OmiColors.error)
        )
        .padding(.horizontal, 16)
    }

    // MARK: - Transcript Views

    /// Expanded state: full-page transcript with back button
    private var fullPageTranscriptView: some View {
        VStack(spacing: 0) {
            // Back to conversations button
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTranscriptCollapsed = true
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Back to Conversations")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(OmiColors.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(OmiColors.backgroundTertiary.opacity(0.5))

            // Full-page transcript
            if appState.liveSpeakerSegments.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 32))
                        .foregroundColor(OmiColors.textTertiary.opacity(0.5))

                    Text("Listening...")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LiveTranscriptView(segments: appState.liveSpeakerSegments)
            }
        }
    }

    // MARK: - Conversation List Section

    private var conversationListSection: some View {
        VStack(spacing: 0) {
            // Section header with search bar
            VStack(spacing: 8) {
                HStack {
                    Text("Past Conversations")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(OmiColors.textSecondary)

                    if searchQuery.isEmpty {
                        // Show "50" or "50 of 224" when total count is available
                        if let total = appState.totalConversationsCount, total > appState.conversations.count {
                            Text("(\(appState.conversations.count) of \(total))")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                        } else {
                            Text("(\(appState.conversations.count))")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    } else {
                        Text("(\(searchResults.count) results)")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    if appState.isLoadingConversations || isSearching {
                        ProgressView()
                            .scaleEffect(0.6)
                    }
                }

                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    TextField("Search conversations...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textPrimary)
                        .onChange(of: searchQuery) { _, newValue in
                            // Feed input to debouncer
                            searchDebouncer.inputQuery = newValue
                        }
                        .onChange(of: searchDebouncer.debouncedQuery) { _, newValue in
                            // Debounced value changed - perform search
                            performSearch(query: newValue)
                        }

                    if !searchQuery.isEmpty {
                        Button(action: {
                            searchQuery = ""
                            searchDebouncer.inputQuery = ""
                            searchResults = []
                            searchError = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OmiColors.backgroundTertiary.opacity(0.5))
                )

                // Filter buttons row
                filterButtonsRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // List - show search results or regular conversations
            if !searchQuery.isEmpty {
                // Search results view
                searchResultsView
            } else {
                // Regular conversation list
                ConversationListView(
                    conversations: appState.conversations,
                    isLoading: appState.isLoadingConversations,
                    error: appState.conversationsError,
                    folders: appState.folders,
                    onSelect: { conversation in
                        AnalyticsManager.shared.memoryListItemClicked(conversationId: conversation.id)
                        selectedConversation = conversation
                    },
                    onRefresh: {
                        Task {
                            await appState.refreshConversations()
                        }
                    },
                    onMoveToFolder: { conversationId, folderId in
                        await appState.moveConversationToFolder(conversationId, folderId: folderId)
                    }
                )
            }
        }
    }

    // MARK: - Search Results View

    private var searchResultsView: some View {
        Group {
            if isSearching {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Searching...")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = searchError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 32))
                        .foregroundColor(OmiColors.textTertiary)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if searchResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(OmiColors.textTertiary.opacity(0.5))
                    Text("No conversations found")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)
                    Text("Try a different search term")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textQuaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(searchResults) { conversation in
                            ConversationRowView(
                                conversation: conversation,
                                onTap: {
                                    AnalyticsManager.shared.memoryListItemClicked(conversationId: conversation.id)
                                    selectedConversation = conversation
                                },
                                folders: appState.folders,
                                onMoveToFolder: { conversationId, folderId in
                                    await appState.moveConversationToFolder(conversationId, folderId: folderId)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - Search

    private func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            searchError = nil
            return
        }

        isSearching = true
        searchError = nil
        log("Search: Starting search for '\(query)'")
        AnalyticsManager.shared.searchQueryEntered(query: query)

        Task {
            do {
                let result = try await APIClient.shared.searchConversations(
                    query: query,
                    page: 1,
                    perPage: 50,
                    includeDiscarded: false
                )
                log("Search: Found \(result.items.count) results")
                searchResults = result.items
                isSearching = false
            } catch {
                logError("Search: Failed", error: error)
                searchError = error.localizedDescription
                searchResults = []
                isSearching = false
            }
        }
    }

    // MARK: - Filter Buttons

    private var filterButtonsRow: some View {
        HStack(spacing: 8) {
            // Starred filter button
            Button(action: {
                Task {
                    await appState.toggleStarredFilter()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: appState.showStarredOnly ? "star.fill" : "star")
                        .font(.system(size: 12))
                    Text("Starred")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(appState.showStarredOnly ? OmiColors.amber : OmiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(appState.showStarredOnly ? OmiColors.amber.opacity(0.15) : OmiColors.backgroundTertiary.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(appState.showStarredOnly ? OmiColors.amber.opacity(0.4) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Date filter button
            Button(action: {
                showDatePicker.toggle()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 12))
                    if let date = appState.selectedDateFilter {
                        Text(formatFilterDate(date))
                            .font(.system(size: 12, weight: .medium))
                        // Clear button
                        Button(action: {
                            Task {
                                await appState.setDateFilter(nil)
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("Date")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundColor(appState.selectedDateFilter != nil ? OmiColors.purplePrimary : OmiColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(appState.selectedDateFilter != nil ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundTertiary.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(appState.selectedDateFilter != nil ? OmiColors.purplePrimary.opacity(0.4) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDatePicker) {
                datePickerPopover
            }

            // Folder filter button (only show if folders exist)
            if !appState.folders.isEmpty {
                Button(action: {
                    showFolderPicker.toggle()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .font(.system(size: 12))
                        if let folderId = appState.selectedFolderId,
                           let folder = appState.folders.first(where: { $0.id == folderId }) {
                            Text(folder.name)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            // Clear button
                            Button(action: {
                                Task {
                                    await appState.setFolderFilter(nil)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("Folder")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundColor(appState.selectedFolderId != nil ? OmiColors.purplePrimary : OmiColors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(appState.selectedFolderId != nil ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundTertiary.opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(appState.selectedFolderId != nil ? OmiColors.purplePrimary.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showFolderPicker) {
                    folderPickerPopover
                }
            }

            Spacer()

            // Clear all filters button (only show if any filter is active)
            if appState.showStarredOnly || appState.selectedDateFilter != nil || appState.selectedFolderId != nil {
                Button(action: {
                    Task {
                        await appState.clearFilters()
                    }
                }) {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }

    private var datePickerPopover: some View {
        VStack(spacing: 12) {
            DatePicker(
                "Select Date",
                selection: Binding(
                    get: { appState.selectedDateFilter ?? Date() },
                    set: { newDate in
                        Task {
                            await appState.setDateFilter(newDate)
                        }
                        showDatePicker = false
                    }
                ),
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
        .padding()
        .frame(width: 300)
        .background(OmiColors.backgroundSecondary)
    }

    private func formatFilterDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private var folderPickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Filter by Folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            ForEach(appState.folders) { folder in
                Button(action: {
                    Task {
                        await appState.setFolderFilter(folder.id)
                    }
                    showFolderPicker = false
                }) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: folder.color) ?? OmiColors.textTertiary)
                            .frame(width: 8, height: 8)
                        Text(folder.name)
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textPrimary)
                        Spacer()
                        if appState.selectedFolderId == folder.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(OmiColors.purplePrimary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(appState.selectedFolderId == folder.id ? OmiColors.purplePrimary.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(minWidth: 180)
        .background(OmiColors.backgroundSecondary)
    }

    // MARK: - Recording Header

    private var recordingHeader: some View {
        HStack(spacing: 16) {
            if appState.isTranscribing {
                // Recording indicator
                recordingIndicator

                Spacer()

                // Duration
                Text(recordingDurationFormatted)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(OmiColors.textSecondary)

                // Finish button
                finishButton
            } else {
                // Not recording - show start button
                Text("Conversations")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                startRecordingButton
            }
        }
    }

    // MARK: - Recording Indicator

    @State private var isPulsing = false

    private var recordingIndicator: some View {
        HStack(spacing: 12) {
            // Pulsing dot
            ZStack {
                Circle()
                    .fill(OmiColors.purplePrimary.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .scaleEffect(isPulsing ? 1.6 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)

                Circle()
                    .fill(OmiColors.purplePrimary)
                    .frame(width: 10, height: 10)
            }
            .animation(
                .easeInOut(duration: 1.0)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }

            // Show inline transcript when collapsed, "Listening" when expanded or no text
            if isTranscriptCollapsed, let latestText = latestTranscriptText {
                // Inline transcript preview - clickable to expand
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTranscriptCollapsed = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Text(latestText)
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 280, alignment: .leading)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(OmiColors.backgroundTertiary.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                Text("Listening")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textPrimary)
            }

            // Audio level waveforms (restored original animation)
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                    AudioLevelWaveformView(
                        level: appState.microphoneAudioLevel,
                        barCount: 8,
                        isActive: appState.isTranscribing
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                    AudioLevelWaveformView(
                        level: appState.systemAudioLevel,
                        barCount: 8,
                        isActive: appState.isTranscribing
                    )
                }
            }
        }
    }

    /// Get the latest transcript text for inline display
    private var latestTranscriptText: String? {
        guard !appState.liveSpeakerSegments.isEmpty else { return nil }
        // Get the last segment's text
        return appState.liveSpeakerSegments.last?.text
    }

    // MARK: - Buttons

    @State private var isFinishing = false
    @State private var showDiscarded = false
    @State private var showError = false
    @State private var errorMessage = ""

    private var finishButton: some View {
        Button(action: {
            guard !isFinishing && !showSavedSuccess && !showDiscarded else { return }
            isFinishing = true
            Task {
                let result = await appState.finishConversation()
                isFinishing = false

                switch result {
                case .saved:
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSavedSuccess = true
                    }
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSavedSuccess = false
                        isTranscriptCollapsed = true
                    }

                case .discarded:
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showDiscarded = true
                    }
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showDiscarded = false
                        isTranscriptCollapsed = true
                    }

                case .error(let message):
                    errorMessage = message
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showError = true
                    }
                    try? await Task.sleep(for: .seconds(3.0))
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showError = false
                    }
                }
            }
        }) {
            HStack(spacing: 6) {
                if isFinishing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else if showSavedSuccess {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                } else if showDiscarded {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                } else if showError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                }
                Text(finishButtonText)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(finishButtonColor)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFinishing || showSavedSuccess || showDiscarded || showError || appState.liveSpeakerSegments.isEmpty)
    }

    private var finishButtonText: String {
        if isFinishing { return "Saving..." }
        if showSavedSuccess { return "Saved!" }
        if showDiscarded { return "Too Short" }
        if showError { return "Failed" }
        return "Finish"
    }

    private var finishButtonColor: Color {
        if isFinishing { return OmiColors.textTertiary }
        if showSavedSuccess { return OmiColors.success }
        if showDiscarded { return OmiColors.warning }
        if showError { return OmiColors.error }
        return OmiColors.purplePrimary
    }

    private var startRecordingButton: some View {
        Button(action: {
            appState.startTranscription()
        }) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12))
                Text("Start Recording")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(OmiColors.purplePrimary)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// Recording duration formatted - separate from conversation duration
    private var recordingDurationFormatted: String {
        let duration = Int(appState.recordingDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

#Preview {
    ConversationsPage(appState: AppState())
        .frame(width: 600, height: 800)
        .background(OmiColors.backgroundSecondary)
}
