import SwiftUI

/// Full detail view for a single conversation
struct ConversationDetailView: View {
    let conversation: ServerConversation
    let onBack: () -> Void

    /// Format date for display
    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d, yyyy"
        return formatter.string(from: conversation.createdAt)
    }

    /// Format time for display
    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: conversation.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with back button
            headerView

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Overview section
                    if !conversation.overview.isEmpty {
                        overviewSection
                    }

                    // Metadata chips
                    metadataSection

                    // Transcript section
                    if !conversation.transcriptSegments.isEmpty {
                        transcriptSection
                    }

                    // Action items section
                    if !conversation.structured.actionItems.isEmpty {
                        actionItemsSection
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            // Back button
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("Back")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundColor(OmiColors.purplePrimary)
            }
            .buttonStyle(.plain)

            // Emoji
            Text(conversation.structured.emoji.isEmpty ? "💬" : conversation.structured.emoji)
                .font(.system(size: 28))

            // Title
            Text(conversation.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)
                .lineLimit(1)

            Spacer()

            // Status badge
            if conversation.status != .completed {
                statusBadge
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(OmiColors.backgroundTertiary.opacity(0.5))
    }

    private var statusBadge: some View {
        Text(conversation.status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.2))
            )
    }

    private var statusColor: Color {
        switch conversation.status {
        case .completed:
            return OmiColors.success
        case .processing, .merging:
            return OmiColors.info
        case .inProgress:
            return OmiColors.warning
        case .failed:
            return OmiColors.error
        }
    }

    // MARK: - Overview Section

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overview")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(OmiColors.textSecondary)

            Text(conversation.overview)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .lineSpacing(4)
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        HStack(spacing: 12) {
            // Date chip
            metadataChip(icon: "calendar", text: formattedDate)

            // Time chip
            metadataChip(icon: "clock", text: formattedTime)

            // Duration chip
            metadataChip(icon: "hourglass", text: conversation.formattedDuration)

            // Category chip
            if !conversation.structured.category.isEmpty && conversation.structured.category != "other" {
                metadataChip(icon: "tag", text: conversation.structured.category.capitalized)
            }

            Spacer()
        }
    }

    private func metadataChip(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(OmiColors.textTertiary)

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(OmiColors.backgroundTertiary)
        )
    }

    // MARK: - Transcript Section

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Text("\(conversation.transcriptSegments.count) segments")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
            }

            // Transcript content
            VStack(spacing: 12) {
                ForEach(conversation.transcriptSegments) { segment in
                    SpeakerBubbleView(
                        segment: segment,
                        isUser: segment.isUser
                    )
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(OmiColors.backgroundSecondary)
            )
        }
    }

    // MARK: - Action Items Section

    private var actionItemsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Action Items")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Text("\(conversation.structured.actionItems.count) items")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(conversation.structured.actionItems.filter { !$0.deleted }) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.completed ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundColor(item.completed ? OmiColors.success : OmiColors.textTertiary)

                        Text(item.description)
                            .font(.system(size: 14))
                            .foregroundColor(item.completed ? OmiColors.textTertiary : OmiColors.textPrimary)
                            .strikethrough(item.completed, color: OmiColors.textTertiary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(OmiColors.backgroundTertiary)
                    )
                }
            }
        }
    }
}

#Preview {
    ConversationDetailView(
        conversation: ServerConversation.preview,
        onBack: { }
    )
    .frame(width: 600, height: 800)
    .background(OmiColors.backgroundPrimary)
}

// Preview helper
extension ServerConversation {
    static var preview: ServerConversation {
        // This would need to be implemented with a proper initializer
        // For now, previews won't work without mock data
        fatalError("Preview not implemented")
    }
}
