import SwiftUI
import MarkdownUI

// MARK: - Onboarding Chat View

struct OnboardingChatView: View {
    let onComplete: ([String: String]) -> Void
    let onSkip: () -> Void

    @ObservedObject private var agentService = AgentSDKService.shared
    @State private var messages: [ChatMessage] = []
    @State private var conversationHistory: [(role: String, content: String)] = []
    @State private var collectedData: [String: String] = [:]
    @State private var inputText: String = ""
    @State private var isProcessing: Bool = false
    @State private var hasStarted: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Let's get to know you")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                Button(action: onSkip) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if !hasStarted {
                            // Welcome screen
                            VStack(spacing: 16) {
                                if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                                   let logoImage = NSImage(contentsOf: logoURL) {
                                    Image(nsImage: logoImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 48, height: 48)
                                }

                                Text("Hi! I'm your Omi assistant")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(OmiColors.textPrimary)

                                Text("I'd love to learn about you to personalize your experience.\n\nFeel free to ask me anything!")
                                    .font(.system(size: 14))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)

                                Button(action: startChat) {
                                    Text("Start Chat")
                                        .font(.system(size: 14, weight: .medium))
                                        .frame(maxWidth: 200)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }
                            .padding(.vertical, 40)
                            .frame(maxWidth: .infinity)
                        } else {
                            // Chat messages
                            ForEach(messages) { message in
                                OnboardingChatBubble(message: message)
                                    .id(message.id)
                            }

                            // Typing indicator
                            if isProcessing {
                                HStack(spacing: 12) {
                                    if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                                       let logoImage = NSImage(contentsOf: logoURL) {
                                        Image(nsImage: logoImage)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 20, height: 20)
                                            .frame(width: 32, height: 32)
                                            .background(OmiColors.backgroundTertiary)
                                            .clipShape(Circle())
                                    }

                                    TypingIndicator()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("typing")
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isProcessing) { _, processing in
                    if processing {
                        withAnimation {
                            proxy.scrollTo("typing", anchor: .bottom)
                        }
                    }
                }
            }

            if hasStarted {
                Divider()
                    .background(OmiColors.backgroundTertiary)

                // Input area
                HStack(spacing: 12) {
                    TextField("Type your message...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textPrimary)
                        .focused($isInputFocused)
                        .padding(12)
                        .lineLimit(1...3)
                        .onSubmit {
                            sendMessage()
                        }
                        .frame(maxWidth: .infinity)
                        .background(OmiColors.backgroundSecondary)
                        .cornerRadius(20)

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(canSend ? OmiColors.purplePrimary : OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: - Actions

    private func startChat() {
        hasStarted = true
        isInputFocused = true

        // Send initial greeting from AI
        Task {
            await getAIResponse()
        }
    }

    private func sendMessage() {
        guard canSend else { return }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        // Add user message to UI
        let userMessage = ChatMessage(
            text: text,
            sender: .user,
            isStreaming: false
        )
        messages.append(userMessage)

        // Add to conversation history
        conversationHistory.append((role: "user", content: text))

        // Get AI response
        Task {
            await getAIResponse()
        }
    }

    private func getAIResponse() async {
        guard agentService.isHealthy else {
            let errorMessage = ChatMessage(
                text: "I'm having trouble connecting. Please try again.",
                sender: .ai,
                isStreaming: false
            )
            messages.append(errorMessage)
            return
        }

        isProcessing = true

        do {
            // Call agent with conversation history
            let (response, toolCalls) = try await agentService.chat(
                messages: conversationHistory,
                collectedData: collectedData
            )

            // Add AI response to conversation history
            conversationHistory.append((role: "assistant", content: response))

            // Process tool calls
            var didCollectData = false
            var shouldComplete = false

            for toolCall in toolCalls {
                switch toolCall.name {
                case "save_field":
                    if let field = toolCall.input["field"],
                       let value = toolCall.input["value"] {
                        collectedData[field] = value
                        UserDefaults.standard.set(value, forKey: "onboarding_\(field)")
                        log("Collected onboarding data: \(field) = \(value)")
                        didCollectData = true
                    }

                case "complete_onboarding":
                    shouldComplete = true
                    log("AI signaled onboarding complete")

                default:
                    break
                }
            }

            // Add AI message to UI
            if !response.isEmpty {
                let aiMessage = ChatMessage(
                    text: response,
                    sender: .ai,
                    isStreaming: false
                )
                messages.append(aiMessage)
            }

            // Complete onboarding if signaled
            if shouldComplete {
                // Small delay so user can read the final message
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                completeOnboarding()
            }

        } catch {
            logError("OnboardingChat: Failed to get AI response", error: error)

            let errorMessage = ChatMessage(
                text: "Sorry, I had trouble processing that. Could you try again?",
                sender: .ai,
                isStreaming: false
            )
            messages.append(errorMessage)
        }

        isProcessing = false
    }

    private func completeOnboarding() {
        log("OnboardingChat: Complete with collected data: \(collectedData)")
        onComplete(collectedData)
    }
}

// MARK: - Onboarding Chat Bubble

struct OnboardingChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.sender == .ai {
                // Omi logo
                if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                   let logoImage = NSImage(contentsOf: logoURL) {
                    Image(nsImage: logoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .frame(width: 32, height: 32)
                        .background(OmiColors.backgroundTertiary)
                        .clipShape(Circle())
                }
            }

            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                Markdown(message.text)
                    .markdownTheme(message.sender == .user ? .userMessage : .aiMessage)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.sender == .user ? OmiColors.purplePrimary : OmiColors.backgroundSecondary)
                    .cornerRadius(18)

                Text(message.createdAt, style: .time)
                    .font(.system(size: 10))
                    .foregroundColor(OmiColors.textTertiary)
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
    }
}
