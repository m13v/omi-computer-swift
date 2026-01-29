import SwiftUI

struct ConversationsPage: View {
    @ObservedObject var appState: AppState
    @State private var selectedConversation: ServerConversation? = nil

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

            // Live transcript when recording
            if appState.isTranscribing && !appState.liveSpeakerSegments.isEmpty {
                LiveTranscriptView(segments: appState.liveSpeakerSegments)
                    .frame(maxHeight: 200)

                Divider()
                    .background(OmiColors.backgroundTertiary)
            }

            // Conversation list (always visible below)
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
                Text(formattedDuration)
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
                    level: appState.microphoneAudioLevel,
                    label: "Mic"
                )

                audioLevelIndicator(
                    icon: "speaker.wave.2.fill",
                    level: appState.systemAudioLevel,
                    label: "System"
                )
            }
            .padding(.leading, 8)
        }
    }

    private func audioLevelIndicator(icon: String, level: Float, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(level > 0.1 ? OmiColors.success : OmiColors.textTertiary)

            // Simple level bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OmiColors.backgroundTertiary)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(level > 0.5 ? OmiColors.success : OmiColors.purplePrimary)
                        .frame(width: geo.size.width * CGFloat(min(level, 1.0)))
                }
            }
            .frame(width: 40, height: 4)
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

    private var formattedDuration: String {
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
