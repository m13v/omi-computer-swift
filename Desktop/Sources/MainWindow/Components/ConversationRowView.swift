import SwiftUI
import AppKit

/// Row view for a conversation in the list
struct ConversationRowView: View {
    let conversation: ServerConversation
    let onTap: () -> Void
    let folders: [Folder]
    let onMoveToFolder: (String, String?) async -> Void

    // Multi-select support
    var isMultiSelectMode: Bool = false
    var isSelected: Bool = false
    var onToggleSelection: (() -> Void)? = nil

    @EnvironmentObject var appState: AppState
    @State private var isStarring = false

    // Context menu action states
    @State private var showEditDialog = false
    @State private var showDeleteConfirmation = false
    @State private var editedTitle: String = ""
    @State private var isDeleting = false
    @State private var isUpdatingTitle = false

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

    private func toggleStar() async {
        guard !isStarring else { return }
        isStarring = true
        let newStarred = !conversation.starred

        do {
            try await APIClient.shared.setConversationStarred(id: conversation.id, starred: newStarred)
            await MainActor.run {
                appState.setConversationStarred(conversation.id, starred: newStarred)
            }
        } catch {
            log("Failed to update starred status: \(error)")
        }

        isStarring = false
    }

    // MARK: - Context Menu Actions

    private func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(conversation.transcript, forType: .string)
        log("Copied transcript to clipboard")
    }

    private func copyLink() {
        let link = "https://h.omi.me/conversations/\(conversation.id)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        log("Copied conversation link to clipboard")
    }

    private func deleteConversation() async {
        guard !isDeleting else { return }
        isDeleting = true

        do {
            try await APIClient.shared.deleteConversation(id: conversation.id)
            await MainActor.run {
                appState.deleteConversationLocally(conversation.id)
            }
            log("Deleted conversation \(conversation.id)")
        } catch {
            log("Failed to delete conversation: \(error)")
        }

        isDeleting = false
    }

    private func updateTitle() async {
        guard !isUpdatingTitle, !editedTitle.isEmpty else { return }
        isUpdatingTitle = true

        do {
            try await APIClient.shared.updateConversationTitle(id: conversation.id, title: editedTitle)
            await MainActor.run {
                appState.updateConversationTitle(conversation.id, title: editedTitle)
            }
            log("Updated conversation title to: \(editedTitle)")
        } catch {
            log("Failed to update title: \(error)")
        }

        isUpdatingTitle = false
    }

    var body: some View {
        Button(action: {
            if isMultiSelectMode {
                onToggleSelection?()
            } else {
                onTap()
            }
        }) {
            HStack(spacing: 12) {
                // Checkbox for multi-select mode
                if isMultiSelectMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundColor(isSelected ? OmiColors.purplePrimary : OmiColors.textTertiary)
                }

                // Title and overview
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(conversation.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)
                            .lineLimit(1)

                        // Show ID for untitled conversations
                        if conversation.structured.title.isEmpty {
                            Text("(\(conversation.id.prefix(8))...)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(OmiColors.textQuaternary)
                        }
                    }

                    if !conversation.overview.isEmpty {
                        Text(conversation.overview)
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Star button
                Button(action: {
                    Task {
                        await toggleStar()
                    }
                }) {
                    Image(systemName: conversation.starred ? "star.fill" : "star")
                        .font(.system(size: 14))
                        .foregroundColor(conversation.starred ? OmiColors.amber : OmiColors.textTertiary)
                        .opacity(isStarring ? 0.5 : 1.0)
                }
                .buttonStyle(.plain)

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
                    .fill(isSelected ? OmiColors.purplePrimary.opacity(0.2) : (isNewlyCreated ? OmiColors.purplePrimary.opacity(0.15) : OmiColors.backgroundTertiary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? OmiColors.purplePrimary.opacity(0.5) : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: copyTranscript) {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }

            Button(action: copyLink) {
                Label("Copy Link", systemImage: "link")
            }

            Divider()

            Button(action: {
                editedTitle = conversation.title
                showEditDialog = true
            }) {
                Label("Edit Title", systemImage: "pencil")
            }

            // Move to Folder submenu
            if !folders.isEmpty {
                Menu {
                    // Option to remove from folder
                    if conversation.folderId != nil {
                        Button(action: {
                            Task {
                                await onMoveToFolder(conversation.id, nil)
                            }
                        }) {
                            Label("Remove from Folder", systemImage: "folder.badge.minus")
                        }
                        Divider()
                    }

                    // List available folders
                    ForEach(folders) { folder in
                        Button(action: {
                            Task {
                                await onMoveToFolder(conversation.id, folder.id)
                            }
                        }) {
                            HStack {
                                Text(folder.name)
                                if conversation.folderId == folder.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        .disabled(conversation.folderId == folder.id)
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }

            Divider()

            Button(role: .destructive, action: {
                showDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
        .alert("Edit Conversation Title", isPresented: $showEditDialog) {
            TextField("Title", text: $editedTitle)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                Task {
                    await updateTitle()
                }
            }
            .disabled(editedTitle.isEmpty || isUpdatingTitle)
        } message: {
            Text("Enter a new title for this conversation")
        }
        .alert("Delete Conversation", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await deleteConversation()
                }
            }
        } message: {
            Text("Are you sure you want to delete this conversation? This action cannot be undone.")
        }
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
