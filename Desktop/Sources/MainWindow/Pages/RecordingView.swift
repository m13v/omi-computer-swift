import SwiftUI

/// Recording view showing recording status, audio levels, and live transcript
struct RecordingView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Recording header with status and audio levels
            RecordingHeaderView(appState: appState)
                .padding(16)

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Live transcript
            if appState.liveSpeakerSegments.isEmpty {
                emptyTranscriptView
            } else {
                LiveTranscriptView(segments: appState.liveSpeakerSegments)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTranscriptView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)
                .opacity(0.5)

            Text("Listening...")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            Text("Start speaking and your transcript will appear here")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

#Preview {
    RecordingView(appState: AppState())
        .frame(width: 500, height: 600)
        .background(OmiColors.backgroundSecondary)
}
