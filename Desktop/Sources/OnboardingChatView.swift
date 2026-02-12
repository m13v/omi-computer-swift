import SwiftUI
import MarkdownUI

// MARK: - Onboarding Chat Question

struct OnboardingChatQuestion {
    let id: String
    let agentPrompt: String  // What to send to the agent
    let quickReplies: [String]?  // Optional quick reply buttons
    let allowFreeText: Bool  // Allow typing custom response
    let saveKey: String?  // Key to save response under (nil = don't save)

    init(id: String, agentPrompt: String, quickReplies: [String]? = nil, allowFreeText: Bool = true, saveKey: String? = nil) {
        self.id = id
        self.agentPrompt = agentPrompt
        self.quickReplies = quickReplies
        self.allowFreeText = allowFreeText
        self.saveKey = saveKey
    }
}

// MARK: - Onboarding Chat View

struct OnboardingChatView: View {
    let onComplete: ([String: String]) -> Void
    let onSkip: () -> Void

    @ObservedObject private var agentService = AgentSDKService.shared
    @State private var messages: [ChatMessage] = []
    @State private var currentQuestionIndex = 0
    @State private var responses: [String: String] = [:]
    @State private var isProcessing = false
    @State private var inputText = ""
    @State private var hasStarted = false
    @FocusState private var isInputFocused: Bool

    // Onboarding questions sequence
    private let questions: [OnboardingChatQuestion] = [
        OnboardingChatQuestion(
            id: "welcome",
            agentPrompt: "You are greeting a new user to Omi, an AI assistant that helps with focus and productivity. Give them a warm, brief welcome (2-3 sentences max) and ask what brings them to Omi today.",
            quickReplies: nil,
            allowFreeText: false,
            saveKey: nil  // Don't save welcome message
        ),
        OnboardingChatQuestion(
            id: "motivation",
            agentPrompt: "The user wants to try Omi. Ask them in a friendly, conversational way what their main goal is. Keep it brief (1-2 sentences).",
            quickReplies: ["Stay focused", "Boost productivity", "Remember conversations", "Just exploring"],
            allowFreeText: true,
            saveKey: "motivation"
        ),
        OnboardingChatQuestion(
            id: "use_case",
            agentPrompt: "Based on their goal: '\(response_placeholder)', ask them briefly (1-2 sentences) what kind of work or activities they'd like help with.",
            quickReplies: ["Work meetings", "Deep focus time", "Learning & research", "Creative work"],
            allowFreeText: true,
            saveKey: "use_case"
        ),
        OnboardingChatQuestion(
            id: "confirmation",
            agentPrompt: "Acknowledge their answers warmly and briefly (2-3 sentences). Tell them you understand they want to use Omi for '\(response_placeholder)' and you're excited to help. Ask if they're ready to finish setup.",
            quickReplies: ["Yes, let's go!", "Tell me more first"],
            allowFreeText: false,
            saveKey: nil
        )
    ]

    var currentQuestion: OnboardingChatQuestion? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        if messages.isEmpty {
                            // Empty state before chat starts
                            VStack(spacing: 16) {
                                if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                                   let logoImage = NSImage(contentsOf: logoURL) {
                                    Image(nsImage: logoImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 48, height: 48)
                                }

                                Text("Let's get to know each other")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(OmiColors.textPrimary)

                                Text("I'll ask you a few quick questions to personalize your experience")
                                    .font(.system(size: 13))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 40)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.top, 40)
                        } else {
                            LazyVStack(spacing: 16) {
                                ForEach(messages) { message in
                                    OnboardingChatBubble(message: message)
                                        .id(message.id)
                                }

                                // Typing indicator
                                if isProcessing {
                                    HStack(alignment: .top, spacing: 12) {
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

                                        TypingIndicator()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding()
                        }
                    }
                    .onChange(of: messages.count) { _, _ in
                        // Auto-scroll to bottom when messages change
                        if let lastMessage = messages.last {
                            withAnimation {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()
                .background(OmiColors.backgroundTertiary)

            // Input area
            if hasStarted {
                inputArea
                    .padding()
            } else {
                // Start button
                VStack(spacing: 12) {
                    Button(action: startChat) {
                        Text("Start Chat")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(action: onSkip) {
                        Text("Skip this step")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
        }
        .background(OmiColors.backgroundPrimary)
        .onAppear {
            log("OnboardingChatView appeared, agent healthy: \(agentService.isHealthy)")
        }
    }

    // MARK: - Input Area

    @ViewBuilder
    private var inputArea: some View {
        VStack(spacing: 12) {
            // Quick reply buttons (if current question has them)
            if let quickReplies = currentQuestion?.quickReplies, !quickReplies.isEmpty {
                QuickReplyButtons(options: quickReplies) { reply in
                    handleUserResponse(reply)
                }
            }

            // Text input (if current question allows free text)
            if currentQuestion?.allowFreeText == true {
                HStack(spacing: 12) {
                    TextField("Type your answer...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textPrimary)
                        .focused($isInputFocused)
                        .padding(12)
                        .lineLimit(1...3)
                        .onSubmit {
                            sendTextResponse()
                        }
                        .frame(maxWidth: .infinity)
                        .background(OmiColors.backgroundSecondary)
                        .cornerRadius(20)

                    Button(action: sendTextResponse) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(canSend ? OmiColors.purplePrimary : OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                }
            }

            // Skip button for optional questions
            if currentQuestion?.saveKey != nil {
                Button(action: skipQuestion) {
                    Text("Skip")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isProcessing
    }

    // MARK: - Actions

    private func startChat() {
        hasStarted = true
        // Send first question
        Task {
            await askNextQuestion()
        }
    }

    private func sendTextResponse() {
        guard canSend else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        handleUserResponse(text)
    }

    private func skipQuestion() {
        // Move to next question without saving response
        currentQuestionIndex += 1
        Task {
            await askNextQuestion()
        }
    }

    private func handleUserResponse(_ text: String) {
        // Add user message
        let userMessage = ChatMessage(
            text: text,
            sender: .user,
            isStreaming: false
        )
        messages.append(userMessage)

        // Save response if this question has a save key
        if let saveKey = currentQuestion?.saveKey {
            responses[saveKey] = text
            log("Saved onboarding response: \(saveKey) = \(text)")
        }

        // Move to next question
        currentQuestionIndex += 1

        // Check if we're done
        if currentQuestionIndex >= questions.count {
            // Chat complete
            completeOnboarding()
        } else {
            // Ask next question
            Task {
                await askNextQuestion()
            }
        }
    }

    private func askNextQuestion() async {
        guard let question = currentQuestion else {
            completeOnboarding()
            return
        }

        guard agentService.isHealthy else {
            // Agent service not available, show error
            let errorMessage = ChatMessage(
                text: "I'm having trouble connecting. Let's continue with the setup.",
                sender: .ai,
                isStreaming: false
            )
            messages.append(errorMessage)

            // Auto-advance after error
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                completeOnboarding()
            }
            return
        }

        isProcessing = true

        do {
            // Build prompt with response placeholders
            var prompt = question.agentPrompt
            if prompt.contains("\\(response_placeholder)") {
                // Replace with user's last meaningful response
                let lastResponse = responses.values.last ?? "helping them"
                prompt = prompt.replacingOccurrences(of: "\\(response_placeholder)", with: lastResponse)
            }

            // Get agent response
            let response = try await agentService.runAgent(
                prompt: prompt,
                context: responses
            )

            // Add AI message
            let aiMessage = ChatMessage(
                text: response,
                sender: .ai,
                isStreaming: false
            )
            messages.append(aiMessage)

            log("OnboardingChat: Question \(question.id) answered")

        } catch {
            logError("OnboardingChat: Failed to get agent response", error: error)

            // Fallback message
            let fallbackMessage = ChatMessage(
                text: "Let's continue with the setup!",
                sender: .ai,
                isStreaming: false
            )
            messages.append(fallbackMessage)
        }

        isProcessing = false
    }

    private func completeOnboarding() {
        log("OnboardingChat: Complete with \(responses.count) responses")
        AnalyticsManager.shared.trackEvent("onboarding_chat_completed", properties: [
            "question_count": questions.count,
            "response_count": responses.count
        ])

        // Call completion handler with collected data
        onComplete(responses)
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

// MARK: - Quick Reply Buttons

struct QuickReplyButtons: View {
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button(action: { onSelect(option) }) {
                    Text(option)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
    }
}

// MARK: - Typing Indicator (Reused from ChatPage)

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

// MARK: - Markdown Themes (Reused from ChatPage)

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
        .strong {
            FontWeight(.semibold)
        }
        .link {
            ForegroundColor(OmiColors.purplePrimary)
        }
}
