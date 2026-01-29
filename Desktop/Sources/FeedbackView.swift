import SwiftUI
import Sentry

/// Window controller for the feedback dialog
class FeedbackWindow {
    private static var window: NSWindow?

    static func show(userEmail: String?) {
        // Close existing window if any
        window?.close()

        let feedbackView = FeedbackView(userEmail: userEmail) {
            window?.close()
            window = nil
        }

        let hostingController = NSHostingController(rootView: feedbackView)

        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Report Issue"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 400, height: 300))
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.level = .floating

        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
    }
}

/// SwiftUI view for collecting user feedback
struct FeedbackView: View {
    let userEmail: String?
    let onDismiss: () -> Void

    @State private var feedbackText: String = ""
    @State private var name: String = ""
    @State private var email: String = ""
    @State private var isSubmitting: Bool = false
    @State private var showSuccess: Bool = false

    init(userEmail: String?, onDismiss: @escaping () -> Void) {
        self.userEmail = userEmail
        self.onDismiss = onDismiss
        // Pre-fill email from auth
        _email = State(initialValue: userEmail ?? "")
        // Pre-fill name from AuthService
        _name = State(initialValue: AuthService.shared.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showSuccess {
                // Success state
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)

                    Text("Thanks for your feedback!")
                        .font(.headline)

                    Text("We'll look into this issue.")
                        .foregroundColor(.secondary)

                    Button("Close") {
                        onDismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Form state
                Text("Report an Issue")
                    .font(.headline)

                Text("Describe what went wrong or what you expected to happen.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $feedbackText)
                    .font(.body)
                    .frame(minHeight: 100)
                    .border(Color.gray.opacity(0.3), width: 1)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Your name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Email")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("your@email.com", text: $email)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button("Cancel") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Submit") {
                        submitFeedback()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }

    private func submitFeedback() {
        isSubmitting = true

        // Create a Sentry event ID (capture a message to attach feedback to)
        let eventId = SentrySDK.capture(message: "User Feedback Submitted")

        // Create feedback using new API
        let feedback = SentryFeedback(
            message: feedbackText.trimmingCharacters(in: .whitespacesAndNewlines),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            associatedEventId: eventId
        )

        // Submit to Sentry
        SentrySDK.capture(feedback: feedback)

        log("User feedback submitted to Sentry")

        // Show success
        withAnimation {
            showSuccess = true
            isSubmitting = false
        }
    }
}
