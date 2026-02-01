import SwiftUI

/// Sidebar showing chat sessions grouped by date
struct ChatSessionsSidebar: View {
    @ObservedObject var chatProvider: ChatProvider

    @State private var isTogglingStarredFilter = false

    private let sidebarWidth: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            // New Chat button and starred filter
            VStack(spacing: 8) {
                newChatButton
                starredFilterButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Sessions list
            if chatProvider.isLoadingSessions {
                loadingView
            } else if chatProvider.sessions.isEmpty {
                emptyStateView
            } else {
                sessionsList
            }
        }
        .frame(width: sidebarWidth)
        .background(OmiColors.backgroundSecondary)
    }

    // MARK: - New Chat Button

    private var newChatButton: some View {
        Button(action: {
            Task {
                _ = await chatProvider.createNewSession()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))

                Text("New Chat")
                    .font(.system(size: 14, weight: .medium))

                Spacer()
            }
            .foregroundColor(OmiColors.purplePrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Starred Filter Button

    private var starredFilterButton: some View {
        Button(action: {
            Task {
                isTogglingStarredFilter = true
                await chatProvider.toggleStarredFilter()
                isTogglingStarredFilter = false
            }
        }) {
            HStack(spacing: 6) {
                if isTogglingStarredFilter {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: chatProvider.showStarredOnly ? "star.fill" : "star")
                        .font(.system(size: 12))
                }
                Text("Starred")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundColor(chatProvider.showStarredOnly ? OmiColors.amber : OmiColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(chatProvider.showStarredOnly ? OmiColors.amber.opacity(0.15) : OmiColors.backgroundTertiary.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(chatProvider.showStarredOnly ? OmiColors.amber.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isTogglingStarredFilter)
    }

    // MARK: - Sessions List

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(chatProvider.groupedSessions, id: \.0) { group, sessions in
                    // Group header
                    Text(group)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    // Sessions in group
                    ForEach(sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: chatProvider.currentSession?.id == session.id,
                            onSelect: {
                                Task {
                                    await chatProvider.selectSession(session)
                                }
                            },
                            onDelete: {
                                Task {
                                    await chatProvider.deleteSession(session)
                                }
                            },
                            onToggleStar: {
                                Task {
                                    await chatProvider.toggleStarred(session)
                                }
                            }
                        )
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Loading & Empty States

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading chats...")
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textTertiary)
                .padding(.top, 8)
            Spacer()
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: chatProvider.showStarredOnly ? "star" : "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(OmiColors.textTertiary)

            Text(chatProvider.showStarredOnly ? "No starred chats" : "No chats yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            Text(chatProvider.showStarredOnly ? "Star a chat to see it here" : "Start a conversation")
                .font(.system(size: 12))
                .foregroundColor(OmiColors.textTertiary)
            Spacer()
        }
        .padding()
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onToggleStar: () -> Void

    @State private var isHovering = false
    @State private var showDeleteConfirm = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Star indicator
                if session.starred {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? OmiColors.purplePrimary : OmiColors.textPrimary)
                        .lineLimit(1)

                    if let preview = session.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Hover actions
                if isHovering {
                    HStack(spacing: 4) {
                        // Star/unstar button
                        Button(action: onToggleStar) {
                            Image(systemName: session.starred ? "star.fill" : "star")
                                .font(.system(size: 11))
                                .foregroundColor(session.starred ? .yellow : OmiColors.textTertiary)
                        }
                        .buttonStyle(.plain)

                        // Delete button
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? OmiColors.backgroundTertiary : (isHovering ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering = $0 }
        .alert("Delete Chat?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("This will permanently delete this chat and all its messages.")
        }
    }
}

#Preview {
    ChatSessionsSidebar(chatProvider: ChatProvider())
        .frame(height: 500)
}
