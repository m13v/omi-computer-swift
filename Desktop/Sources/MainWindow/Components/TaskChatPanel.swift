import SwiftUI

/// Compact chat panel for the task sidebar.
/// Displays task-scoped chat using the shared ChatProvider via TaskChatCoordinator.
struct TaskChatPanel: View {
    @ObservedObject var chatProvider: ChatProvider
    @ObservedObject var coordinator: TaskChatCoordinator
    let task: TaskActionItem?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Compact header
            panelHeader

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Messages area
            ChatMessagesView(
                messages: chatProvider.messages,
                isSending: chatProvider.isSending,
                hasMoreMessages: chatProvider.hasMoreMessages,
                isLoadingMoreMessages: chatProvider.isLoadingMoreMessages,
                isLoadingInitial: chatProvider.isLoading,
                app: nil,
                onLoadMore: { await chatProvider.loadMoreMessages() },
                onRate: { messageId, rating in
                    Task { await chatProvider.rateMessage(messageId, rating: rating) }
                },
                welcomeContent: { taskWelcome }
            )

            // Input area
            ChatInputView(
                onSend: { text in
                    Task { await chatProvider.sendMessage(text) }
                },
                isSending: chatProvider.isSending,
                placeholder: "Ask about this task..."
            )
            .padding(12)
        }
        .background(OmiColors.backgroundPrimary)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textSecondary)

            Text("Task Chat")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            if let task = task {
                Text(task.description)
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OmiColors.textTertiary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close chat panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OmiColors.backgroundTertiary.opacity(0.5))
    }

    // MARK: - Welcome

    private var taskWelcome: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(OmiColors.textTertiary.opacity(0.5))

            Text("Chat about this task")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            Text("Ask questions, get suggestions, or discuss implementation details.")
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
