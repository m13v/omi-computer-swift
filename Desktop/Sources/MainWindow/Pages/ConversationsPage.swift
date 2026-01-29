import SwiftUI
import Combine

// MARK: - Search Debouncer

/// Debounces search queries to avoid excessive API calls
class SearchDebouncer: ObservableObject {
    @Published var debouncedQuery: String = ""
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Observe changes to debouncedQuery with 500ms delay
        $debouncedQuery
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                // This triggers the search via onChange in the view
            }
            .store(in: &cancellables)
    }
}

// MARK: - Conversations Page

struct ConversationsPage: View {
    @ObservedObject var appState: AppState
    @State private var selectedConversation: ServerConversation? = nil

    // Splitter state - height of transcript section
    @State private var transcriptHeight: CGFloat = 180
    @State private var isTranscriptCollapsed: Bool = false
    private let minTranscriptHeight: CGFloat = 60
    private let maxTranscriptHeight: CGFloat = 400

    // Success state after finishing conversation
    @State private var showSavedSuccess: Bool = false

    // Search state
    @State private var searchQuery: String = ""
    @State private var searchResults: [ServerConversation] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String? = nil
    @StateObject private var searchDebouncer = SearchDebouncer()

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
        }
    }

    // MARK: - Main View with Recording Header + List

    private var mainConversationsView: some View {
        VStack(spacing: 0) {
            // Recording header (always visible)
            recordingHeader
                .padding(16)

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Live transcript when recording (with draggable splitter)
            if appState.isTranscribing {
                transcriptSection
            }

            // Conversation list (always visible below)
            conversationListSection
        }
    }

    // MARK: - Transcript Section with Splitter

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            // Collapsible transcript area
            if !isTranscriptCollapsed {
                if appState.liveSpeakerSegments.isEmpty {
                    // Empty state
                    VStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.system(size: 32))
                            .foregroundColor(OmiColors.textTertiary.opacity(0.5))

                        Text("Listening...")
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .frame(height: transcriptHeight)
                    .frame(maxWidth: .infinity)
                } else {
                    LiveTranscriptView(segments: appState.liveSpeakerSegments)
                        .frame(height: transcriptHeight)
                }
            }

            // Draggable splitter
            splitterHandle
        }
    }

    private var splitterHandle: some View {
        // Draggable splitter bar with centered chevron button
        ZStack {
            // The splitter line itself - thick enough to grab
            Rectangle()
                .fill(OmiColors.backgroundTertiary)

            // Centered chevron button
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isTranscriptCollapsed.toggle()
                }
            }) {
                Image(systemName: isTranscriptCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(OmiColors.textSecondary)
                    .frame(width: 28, height: 14)
                    .background(
                        Capsule()
                            .fill(OmiColors.backgroundSecondary)
                            .overlay(
                                Capsule()
                                    .strokeBorder(OmiColors.textQuaternary.opacity(0.3), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isTranscriptCollapsed {
                        let newHeight = transcriptHeight + value.translation.height
                        transcriptHeight = min(max(newHeight, minTranscriptHeight), maxTranscriptHeight)
                    }
                }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isTranscriptCollapsed {
                    NSCursor.resizeUpDown.push()
                }
            case .ended:
                NSCursor.pop()
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
                        Text("(\(appState.conversations.count))")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
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
                            searchDebouncer.debouncedQuery = newValue
                        }
                        .onChange(of: searchDebouncer.debouncedQuery) { _, newValue in
                            performSearch(query: newValue)
                        }

                    if !searchQuery.isEmpty {
                        Button(action: {
                            searchQuery = ""
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
                    onSelect: { conversation in
                        selectedConversation = conversation
                    },
                    onRefresh: {
                        Task {
                            await appState.refreshConversations()
                        }
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
                                    selectedConversation = conversation
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

        Task {
            do {
                let result = try await APIClient.shared.searchConversations(
                    query: query,
                    page: 1,
                    perPage: 50,
                    includeDiscarded: false
                )
                searchResults = result.items
                isSearching = false
            } catch {
                searchError = error.localizedDescription
                searchResults = []
                isSearching = false
            }
        }
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

            Text("Listening")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OmiColors.textPrimary)

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

    // MARK: - Buttons

    @State private var isFinishing = false

    private var finishButton: some View {
        Button(action: {
            guard !isFinishing && !showSavedSuccess else { return }
            isFinishing = true
            Task {
                await appState.finishConversation()
                isFinishing = false

                // Show success state
                withAnimation(.easeInOut(duration: 0.3)) {
                    showSavedSuccess = true
                }

                // After 2.5 seconds, collapse transcript and reset
                try? await Task.sleep(for: .seconds(2.5))

                withAnimation(.easeInOut(duration: 0.3)) {
                    showSavedSuccess = false
                    isTranscriptCollapsed = true
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
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                }
                Text(isFinishing ? "Saving..." : (showSavedSuccess ? "Saved!" : "Finish"))
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isFinishing ? OmiColors.textTertiary : (showSavedSuccess ? OmiColors.success : OmiColors.purplePrimary))
            )
        }
        .buttonStyle(.plain)
        .disabled(isFinishing || showSavedSuccess || appState.liveSpeakerSegments.isEmpty)
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
