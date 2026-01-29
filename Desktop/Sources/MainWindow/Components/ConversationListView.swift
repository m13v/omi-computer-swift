import SwiftUI

/// List view showing conversations grouped by date
struct ConversationListView: View {
    let conversations: [ServerConversation]
    let isLoading: Bool
    let error: String?
    let onSelect: (ServerConversation) -> Void
    let onRefresh: () -> Void

    /// Group conversations by date
    private var groupedConversations: [(String, [ServerConversation])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        var groups: [String: [ServerConversation]] = [:]

        for conversation in conversations {
            let conversationDate = calendar.startOfDay(for: conversation.createdAt)
            let groupKey: String

            if conversationDate == today {
                groupKey = "Today"
            } else if conversationDate == yesterday {
                groupKey = "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMM d, yyyy"
                groupKey = formatter.string(from: conversation.createdAt)
            }

            if groups[groupKey] == nil {
                groups[groupKey] = []
            }
            groups[groupKey]?.append(conversation)
        }

        // Sort groups: Today first, then Yesterday, then by date descending
        let sortedKeys = groups.keys.sorted { key1, key2 in
            if key1 == "Today" { return true }
            if key2 == "Today" { return false }
            if key1 == "Yesterday" { return true }
            if key2 == "Yesterday" { return false }

            // Parse dates for comparison
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, yyyy"
            let date1 = formatter.date(from: key1) ?? Date.distantPast
            let date2 = formatter.date(from: key2) ?? Date.distantPast
            return date1 > date2
        }

        return sortedKeys.map { key in
            (key, groups[key]!)
        }
    }

    var body: some View {
        Group {
            if isLoading && conversations.isEmpty {
                loadingView
            } else if let error = error, conversations.isEmpty {
                errorView(error)
            } else if conversations.isEmpty {
                emptyView
            } else {
                conversationList
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(OmiColors.purplePrimary)

            Text("Loading conversations...")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(OmiColors.warning)

            Text("Failed to load conversations")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(OmiColors.textPrimary)

            Text(error)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)

            Button(action: onRefresh) {
                Text("Try Again")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OmiColors.purplePrimary)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text("No Conversations")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Start recording to capture your first conversation")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(groupedConversations, id: \.0) { group, convos in
                    // Date header
                    Text(group)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.top, group == groupedConversations.first?.0 ? 0 : 16)
                        .padding(.bottom, 8)

                    // Conversations in this group
                    ForEach(convos) { conversation in
                        ConversationRowView(
                            conversation: conversation,
                            onTap: { onSelect(conversation) }
                        )
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            onRefresh()
        }
    }
}

#Preview {
    ConversationListView(
        conversations: [],
        isLoading: false,
        error: nil,
        onSelect: { _ in },
        onRefresh: { }
    )
    .frame(width: 400, height: 600)
    .background(OmiColors.backgroundSecondary)
}
