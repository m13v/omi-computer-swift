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
            } else if appState.isTranscribing {
                // Recording mode - show live transcript
                RecordingView(appState: appState)
            } else {
                // List mode - show conversations
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            // Load conversations when view appears (if not recording)
            if !appState.isTranscribing && appState.conversations.isEmpty {
                Task {
                    await appState.loadConversations()
                }
            }
        }
    }
}

#Preview {
    ConversationsPage(appState: AppState())
        .frame(width: 600, height: 800)
        .background(OmiColors.backgroundSecondary)
}
