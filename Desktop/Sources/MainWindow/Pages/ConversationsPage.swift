import SwiftUI

struct ConversationsPage: View {
    @ObservedObject var appState: AppState
    @State private var selectedConversation: ServerConversation? = nil

    // Splitter state - height of transcript section
    @State private var transcriptHeight: CGFloat = 180
    @State private var isTranscriptCollapsed: Bool = false
    private let minTranscriptHeight: CGFloat = 60
    private let maxTranscriptHeight: CGFloat = 400

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
        VStack(spacing: 0) {
            // Visual handle
            HStack {
                Spacer()

                // Collapse/expand button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isTranscriptCollapsed.toggle()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: isTranscriptCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .semibold))

                        Text(isTranscriptCollapsed ? "Show Transcript" : "Hide Transcript")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(OmiColors.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(OmiColors.backgroundTertiary)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                // Drag handle indicator
                if !isTranscriptCollapsed {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OmiColors.textTertiary.opacity(0.4))
                        .frame(width: 40, height: 4)
                }

                Spacer()
            }
            .frame(height: 28)
            .background(OmiColors.backgroundSecondary.opacity(0.5))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isTranscriptCollapsed {
                            let newHeight = transcriptHeight + value.translation.height
                            transcriptHeight = min(max(newHeight, minTranscriptHeight), maxTranscriptHeight)
                        }
                    }
            )
            .onHover { hovering in
                if hovering && !isTranscriptCollapsed {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }

            Divider()
                .background(OmiColors.backgroundTertiary)
        }
    }

    // MARK: - Conversation List Section

    private var conversationListSection: some View {
        VStack(spacing: 0) {
            // Section header
            HStack {
                Text("Past Conversations")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                if appState.isLoadingConversations {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // List
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
        HStack(spacing: 10) {
            // Pulsing dot
            ZStack {
                Circle()
                    .fill(OmiColors.error.opacity(0.3))
                    .frame(width: 20, height: 20)
                    .scaleEffect(isPulsing ? 1.6 : 1.0)
                    .opacity(isPulsing ? 0.0 : 0.6)

                Circle()
                    .fill(OmiColors.error)
                    .frame(width: 10, height: 10)
            }
            .animation(
                .easeInOut(duration: 1.0)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }

            Text("Recording")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OmiColors.textPrimary)

            // Audio level indicators
            HStack(spacing: 12) {
                audioLevelIndicator(
                    icon: "mic.fill",
                    level: appState.microphoneAudioLevel
                )

                audioLevelIndicator(
                    icon: "speaker.wave.2.fill",
                    level: appState.systemAudioLevel
                )
            }
            .padding(.leading, 8)
        }
    }

    private func audioLevelIndicator(icon: String, level: Float) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(level > 0.1 ? OmiColors.success : OmiColors.textTertiary)

            // Simple level bar
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(OmiColors.backgroundTertiary)
                    .frame(width: 40, height: 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.5 ? OmiColors.success : OmiColors.purplePrimary)
                    .frame(width: 40 * CGFloat(min(level, 1.0)), height: 4)
            }
        }
    }

    // MARK: - Buttons

    @State private var isFinishing = false

    private var finishButton: some View {
        Button(action: {
            guard !isFinishing else { return }
            isFinishing = true
            Task {
                await appState.finishConversation()
                isFinishing = false
            }
        }) {
            HStack(spacing: 6) {
                if isFinishing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                }
                Text(isFinishing ? "Finishing..." : "Finish")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isFinishing ? OmiColors.textTertiary : OmiColors.purplePrimary)
            )
        }
        .buttonStyle(.plain)
        .disabled(isFinishing || appState.liveSpeakerSegments.isEmpty)
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
