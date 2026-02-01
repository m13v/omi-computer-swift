import SwiftUI
import MarkdownUI

struct ChatPage: View {
    @StateObject private var appProvider = AppProvider()
    @StateObject private var chatProvider = ChatProvider()
    @State private var inputText = ""
    @State private var showAppPicker = false
    @State private var showHistoryPopover = false

    var selectedApp: OmiApp? {
        guard let appId = chatProvider.selectedAppId else { return nil }
        return appProvider.chatApps.first { $0.id == appId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with app picker
            chatHeader
                .padding()

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Messages area
            messagesView

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Input area
            inputArea
                .padding()
        }
        .background(OmiColors.backgroundPrimary)
        .task {
            await appProvider.fetchApps()
            // Initialize chat: fetch sessions and load messages
            await chatProvider.initialize()
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack {
            // New chat button
            Button(action: {
                Task {
                    _ = await chatProvider.createNewSession()
                }
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("New chat")

            // App selector
            Button(action: { showAppPicker.toggle() }) {
                HStack(spacing: 10) {
                    if let app = selectedApp {
                        // Show selected app
                        AsyncImage(url: URL(string: app.image)) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                Circle()
                                    .fill(OmiColors.backgroundTertiary)
                            }
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Chat App")
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    } else {
                        // Default OMI assistant
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 18))
                            .foregroundColor(OmiColors.purplePrimary)
                            .frame(width: 32, height: 32)
                            .background(OmiColors.backgroundTertiary)
                            .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text("OMI")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Personal Assistant")
                                .font(.system(size: 11))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }

                    if !appProvider.chatApps.isEmpty {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(OmiColors.backgroundSecondary)
                .cornerRadius(20)
            }
            .buttonStyle(.plain)
            .disabled(appProvider.chatApps.isEmpty)
            .popover(isPresented: $showAppPicker, arrowEdge: .bottom) {
                AppPickerPopover(
                    apps: appProvider.chatApps,
                    selectedAppId: Binding(
                        get: { chatProvider.selectedAppId },
                        set: { newAppId in
                            Task {
                                await chatProvider.selectApp(newAppId)
                            }
                        }
                    ),
                    onSelect: { showAppPicker = false }
                )
            }

            Spacer()

            // Clear chat button
            if !chatProvider.messages.isEmpty {
                Button(action: {
                    Task {
                        await chatProvider.clearChat()
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear chat history")
                .disabled(chatProvider.isLoading)
            }

            // History button
            Button(action: { showHistoryPopover.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Chat history")
            .popover(isPresented: $showHistoryPopover, arrowEdge: .bottom) {
                ChatHistoryPopover(
                    chatProvider: chatProvider,
                    onSelect: { showHistoryPopover = false }
                )
            }
        }
    }

    // MARK: - Messages

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Load more button at top
                    if chatProvider.hasMoreMessages {
                        Button {
                            Task {
                                await chatProvider.loadMoreMessages()
                            }
                        } label: {
                            if chatProvider.isLoadingMoreMessages {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Text("Load earlier messages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }

                    if chatProvider.messages.isEmpty && !chatProvider.isLoading {
                        welcomeMessage
                    } else {
                        ForEach(chatProvider.messages) { message in
                            ChatBubble(
                                message: message,
                                app: selectedApp,
                                onRate: { rating in
                                    Task {
                                        await chatProvider.rateMessage(message.id, rating: rating)
                                    }
                                }
                            )
                            .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: chatProvider.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: chatProvider.messages.last?.text) { _, _ in
                // Scroll as streaming text updates
                scrollToBottom(proxy: proxy)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMessage = chatProvider.messages.last {
            withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo(lastMessage.id, anchor: .bottom)
            }
        }
    }

    private var welcomeMessage: some View {
        VStack(spacing: 16) {
            if let app = selectedApp {
                AsyncImage(url: URL(string: app.image)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Circle()
                            .fill(OmiColors.backgroundTertiary)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())

                Text("Chat with \(app.name)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Text(app.description)
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 40)
            } else {
                // Default OMI assistant
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 48))
                    .foregroundColor(OmiColors.purplePrimary)

                Text("Chat with OMI")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Text("Your personal AI assistant that knows you through your memories and conversations")
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(spacing: 12) {
            TextField("Type a message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)
                .padding(12)
                .background(OmiColors.backgroundSecondary)
                .cornerRadius(20)
                .lineLimit(1...5)
                .onSubmit {
                    sendMessage()
                }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(canSend ? OmiColors.purplePrimary : OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !chatProvider.isSending
    }

    // MARK: - Actions

    private func sendMessage() {
        guard canSend else { return }

        let messageText = inputText
        inputText = ""

        // Track chat message sent
        AnalyticsManager.shared.chatMessageSent(messageLength: messageText.count, hasContext: selectedApp != nil)

        Task {
            await chatProvider.sendMessage(messageText)
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    let app: OmiApp?
    let onRate: (Int?) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.sender == .ai {
                // App avatar
                if let app = app {
                    AsyncImage(url: URL(string: app.image)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            Circle()
                                .fill(OmiColors.backgroundTertiary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "brain")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)
                        .frame(width: 32, height: 32)
                        .background(OmiColors.backgroundTertiary)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                if message.isStreaming && message.text.isEmpty {
                    // Show typing indicator for empty streaming message
                    TypingIndicator()
                } else {
                    Markdown(message.text)
                        .markdownTheme(message.sender == .user ? .userMessage : .aiMessage)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(message.sender == .user ? OmiColors.purplePrimary : OmiColors.backgroundSecondary)
                        .cornerRadius(18)
                }

                // Rating buttons and timestamp row for AI messages
                if message.sender == .ai && !message.isStreaming {
                    HStack(spacing: 8) {
                        ratingButtons

                        Text(message.createdAt, style: .time)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                } else if !message.isStreaming || !message.text.isEmpty {
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 10))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }

            if message.sender == .user {
                // User avatar
                Image(systemName: "person.fill")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(OmiColors.backgroundTertiary)
                    .clipShape(Circle())
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var ratingButtons: some View {
        HStack(spacing: 4) {
            // Thumbs up
            Button(action: {
                // Toggle: if already thumbs up, clear rating; otherwise set thumbs up
                let newRating = message.rating == 1 ? nil : 1
                onRate(newRating)
            }) {
                Image(systemName: message.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 11))
                    .foregroundColor(message.rating == 1 ? OmiColors.purplePrimary : OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Helpful response")

            // Thumbs down
            Button(action: {
                // Toggle: if already thumbs down, clear rating; otherwise set thumbs down
                let newRating = message.rating == -1 ? nil : -1
                onRate(newRating)
            }) {
                Image(systemName: message.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 11))
                    .foregroundColor(message.rating == -1 ? .red : OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Not helpful")
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animationPhase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(OmiColors.textTertiary)
                    .frame(width: 8, height: 8)
                    .scaleEffect(animationPhase == index ? 1.2 : 0.8)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(index) * 0.15), value: animationPhase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OmiColors.backgroundSecondary)
        .cornerRadius(18)
        .onAppear {
            animationPhase = 1
        }
    }
}

// MARK: - App Picker Popover

struct AppPickerPopover: View {
    let apps: [OmiApp]
    @Binding var selectedAppId: String?
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select Assistant")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(OmiColors.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 2) {
                    // Default OMI option
                    DefaultOmiRow(isSelected: selectedAppId == nil) {
                        selectedAppId = nil
                        AnalyticsManager.shared.chatAppSelected(appId: nil, appName: "OMI")
                        onSelect()
                    }

                    if !apps.isEmpty {
                        Divider()
                            .padding(.vertical, 4)
                            .padding(.horizontal, 12)

                        ForEach(apps) { app in
                            AppPickerRow(
                                app: app,
                                isSelected: selectedAppId == app.id
                            ) {
                                selectedAppId = app.id
                                AnalyticsManager.shared.chatAppSelected(appId: app.id, appName: app.name)
                                onSelect()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 250)
        .background(OmiColors.backgroundPrimary)
    }
}

struct DefaultOmiRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18))
                    .foregroundColor(OmiColors.purplePrimary)
                    .frame(width: 36, height: 36)
                    .background(OmiColors.backgroundTertiary)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text("OMI")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)

                    Text("Personal Assistant")
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(OmiColors.purplePrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected || isHovering ? OmiColors.backgroundSecondary : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct AppPickerRow: View {
    let app: OmiApp
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                AsyncImage(url: URL(string: app.image)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Circle()
                            .fill(OmiColors.backgroundTertiary)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)

                    Text(app.author)
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(OmiColors.purplePrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected || isHovering ? OmiColors.backgroundSecondary : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Chat History Popover

struct ChatHistoryPopover: View {
    @ObservedObject var chatProvider: ChatProvider
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Chat History")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                // New chat button in header
                Button(action: {
                    Task {
                        _ = await chatProvider.createNewSession()
                        onSelect()
                    }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.purplePrimary)
                }
                .buttonStyle(.plain)
                .help("New chat")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Sessions list
            if chatProvider.isLoadingSessions {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(height: 200)
            } else if chatProvider.sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 24))
                        .foregroundColor(OmiColors.textTertiary)
                    Text("No chats yet")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textSecondary)
                    Spacer()
                }
                .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(chatProvider.groupedSessions, id: \.0) { group, sessions in
                            // Group header
                            Text(group)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(OmiColors.textTertiary)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 6)

                            // Sessions in group
                            ForEach(sessions) { session in
                                HistorySessionRow(
                                    session: session,
                                    isSelected: chatProvider.currentSession?.id == session.id,
                                    onSelect: {
                                        Task {
                                            await chatProvider.selectSession(session)
                                            onSelect()
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            await chatProvider.deleteSession(session)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 320)
        .background(OmiColors.backgroundPrimary)
    }
}

// MARK: - History Session Row

struct HistorySessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

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

                    HStack(spacing: 4) {
                        if let preview = session.preview, !preview.isEmpty {
                            Text(preview)
                                .lineLimit(1)
                        }
                        Text("·")
                        Text(session.createdAt, style: .relative)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(OmiColors.textTertiary)
                    .lineLimit(1)
                }

                Spacer()

                // Delete button on hover
                if isHovering {
                    Button(action: { showDeleteConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isSelected ? OmiColors.backgroundSecondary : (isHovering ? OmiColors.backgroundSecondary.opacity(0.5) : Color.clear))
        }
        .buttonStyle(.plain)
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
    ChatPage()
        .frame(width: 600, height: 700)
}

// MARK: - Markdown Themes

extension Theme {
    static let userMessage = Theme()
        .text {
            ForegroundColor(.white)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            ForegroundColor(.white.opacity(0.9))
            BackgroundColor(.white.opacity(0.15))
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(.white.opacity(0.9))
            UnderlineStyle(.single)
        }

    static let aiMessage = Theme()
        .text {
            ForegroundColor(OmiColors.textPrimary)
            FontSize(14)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            ForegroundColor(OmiColors.textPrimary)
            BackgroundColor(OmiColors.backgroundTertiary)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(13)
                        ForegroundColor(OmiColors.textPrimary)
                    }
            }
            .padding(12)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(8)
        }
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(OmiColors.purplePrimary)
        }
        .listItem { configuration in
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .foregroundColor(OmiColors.textSecondary)
                configuration.label
            }
        }
}
