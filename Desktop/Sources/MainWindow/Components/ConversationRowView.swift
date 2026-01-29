import SwiftUI

/// Row view for a conversation in the list
struct ConversationRowView: View {
    let conversation: ServerConversation
    let onTap: () -> Void

    /// Format relative time (e.g., "2h ago", "Yesterday")
    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: conversation.createdAt, relativeTo: Date())
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Title and overview
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)
                        .lineLimit(1)

                    if !conversation.overview.isEmpty {
                        Text(conversation.overview)
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Time and duration
                VStack(alignment: .trailing, spacing: 4) {
                    Text(relativeTime)
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)

                    Text(conversation.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textQuaternary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.backgroundTertiary)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 12) {
        // Preview would require mock ServerConversation
        Text("ConversationRowView Preview")
            .foregroundColor(.white)
    }
    .padding()
    .background(OmiColors.backgroundPrimary)
}
