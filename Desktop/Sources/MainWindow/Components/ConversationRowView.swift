import SwiftUI

/// Row view for a conversation in the list
struct ConversationRowView: View {
    let conversation: ServerConversation
    let onTap: () -> Void

    /// The timestamp to display (prefer startedAt, fall back to createdAt)
    private var displayDate: Date {
        conversation.startedAt ?? conversation.createdAt
    }

    /// Check if conversation was created less than 1 minute ago (newly added)
    private var isNewlyCreated: Bool {
        Date().timeIntervalSince(conversation.createdAt) < 60
    }

    /// Format timestamp (e.g., "10:43 AM" for today, "Jan 29, 10:43 AM" for other days)
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(displayDate) {
            // Today: just show time
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDateInYesterday(displayDate) {
            // Yesterday: show "Yesterday, time"
            formatter.dateFormat = "'Yesterday,' h:mm a"
        } else if calendar.isDate(displayDate, equalTo: Date(), toGranularity: .year) {
            // This year: show "Mon, Jan 29, 10:43 AM"
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            // Different year: include year
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
        }

        return formatter.string(from: displayDate)
    }

    /// Label for the conversation source
    private var sourceLabel: String {
        switch conversation.source {
        case .desktop: return "Desktop"
        case .omi: return "Omi"
        case .phone: return "Phone"
        case .appleWatch: return "Watch"
        case .workflow: return "Workflow"
        case .screenpipe: return "Screenpipe"
        case .friend, .friendCom: return "Friend"
        case .openglass: return "OpenGlass"
        case .frame: return "Frame"
        case .bee: return "Bee"
        case .limitless: return "Limitless"
        case .plaud: return "Plaud"
        default: return "Unknown"
        }
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

                // Time, duration, and source
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(sourceLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(OmiColors.textTertiary)

                        Text(formattedTimestamp)
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Text(conversation.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textQuaternary)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isNewlyCreated ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundTertiary)
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
