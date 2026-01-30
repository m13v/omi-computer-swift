import Foundation
import Mixpanel
import FirebaseAuth

/// Singleton manager for MixPanel analytics
/// Mirrors the functionality from the Flutter app's MixpanelManager
@MainActor
class MixpanelManager {
    static let shared = MixpanelManager()

    private var isInitialized = false

    // Environment variable key for MixPanel token
    private let tokenKey = "MIXPANEL_PROJECT_TOKEN"

    private init() {}

    // MARK: - Initialization

    /// Initialize MixPanel with the project token from environment
    func initialize() {
        guard !isInitialized else { return }

        guard let token = getToken() else {
            log("MixPanel: No project token found. Set MIXPANEL_PROJECT_TOKEN environment variable.")
            return
        }

        Mixpanel.initialize(token: token)
        Mixpanel.mainInstance().loggingEnabled = false

        isInitialized = true
        log("MixPanel: Initialized successfully")
    }

    /// Get the MixPanel token from environment or .env file
    private func getToken() -> String? {
        // Check environment variable first
        if let token = ProcessInfo.processInfo.environment[tokenKey], !token.isEmpty {
            return token
        }

        // Try to load from .env files (same paths as AppState)
        let envPaths = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            FileManager.default.currentDirectoryPath + "/.env",
            NSHomeDirectory() + "/.omi.env",
            "/Users/matthewdi/omi-computer-swift/.env",
            "/Users/matthewdi/omi/backend/.env"
        ].compactMap { $0 }

        for path in envPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        if key == tokenKey {
                            let value = String(parts[1])
                                .trimmingCharacters(in: .whitespaces)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            if !value.isEmpty {
                                return value
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    // MARK: - User Identification

    /// Identify the current user after sign-in
    func identify() {
        guard isInitialized else { return }

        guard let user = Auth.auth().currentUser else {
            log("MixPanel: Cannot identify - no user signed in")
            return
        }

        Mixpanel.mainInstance().identify(distinctId: user.uid)

        // Set user profile properties
        setPeopleValues(user: user)

        log("MixPanel: Identified user \(user.uid)")
    }

    /// Set user profile properties
    private func setPeopleValues(user: User) {
        var properties: [String: MixpanelType] = [
            "Platform": "macos",
            "App Version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]

        if let email = user.email {
            properties["$email"] = email
        }

        if let name = user.displayName {
            properties["$name"] = name
        }

        Mixpanel.mainInstance().people.set(properties: properties)
    }

    /// Set a specific user property
    func setUserProperty(key: String, value: MixpanelType) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().people.set(property: key, to: value)
    }

    // MARK: - Event Tracking

    /// Track an event with optional properties
    func track(_ eventName: String, properties: [String: MixpanelType]? = nil) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().track(event: eventName, properties: properties)
        log("MixPanel: Tracked event '\(eventName)'")
    }

    /// Start timing an event (call track with same name to finish)
    func startTimingEvent(_ eventName: String) {
        guard isInitialized else { return }
        Mixpanel.mainInstance().time(event: eventName)
    }

    // MARK: - Opt In/Out

    /// Opt in to tracking
    func optInTracking() {
        guard isInitialized else { return }
        Mixpanel.mainInstance().optInTracking()
    }

    /// Opt out of tracking
    func optOutTracking() {
        guard isInitialized else { return }
        Mixpanel.mainInstance().optOutTracking()
    }

    /// Check if tracking is opted out
    var hasOptedOut: Bool {
        guard isInitialized else { return true }
        return Mixpanel.mainInstance().hasOptedOutTracking()
    }

    // MARK: - Reset

    /// Reset the user (call on sign out)
    func reset() {
        guard isInitialized else { return }
        Mixpanel.mainInstance().reset()
        log("MixPanel: Reset user")
    }
}

// MARK: - Analytics Events

extension MixpanelManager {

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {
        // Match Flutter format: "Onboarding Step {stepName} Completed"
        track("Onboarding Step \(stepName) Completed", properties: [
            "step": step
        ])
    }

    func onboardingCompleted() {
        track("Onboarding Completed")
    }

    // MARK: - Authentication Events

    func signInStarted(provider: String) {
        track("Sign In Started", properties: [
            "provider": provider
        ])
    }

    func signInCompleted(provider: String) {
        track("Sign In Completed", properties: [
            "provider": provider
        ])
    }

    func signInFailed(provider: String, error: String) {
        track("Sign In Failed", properties: [
            "provider": provider,
            "error": error
        ])
    }

    func signedOut() {
        track("Signed Out")
    }

    // MARK: - Monitoring Events

    func monitoringStarted() {
        startTimingEvent("Monitoring Session")
        track("Monitoring Started")
    }

    func monitoringStopped() {
        track("Monitoring Session")  // Ends the timed event
        track("Monitoring Stopped")
    }

    func distractionDetected(app: String, windowTitle: String?) {
        var properties: [String: MixpanelType] = [
            "app": app
        ]
        if let title = windowTitle {
            properties["window_title"] = title
        }
        track("Distraction Detected", properties: properties)
    }

    func focusRestored(app: String) {
        track("Focus Restored", properties: [
            "app": app
        ])
    }

    // MARK: - Recording Events (matches Flutter: Phone Mic Recording)

    func transcriptionStarted() {
        startTimingEvent("Phone Mic Recording Session")
        track("Phone Mic Recording Started")
    }

    func transcriptionStopped(wordCount: Int) {
        track("Phone Mic Recording Session")  // Ends the timed event
        track("Phone Mic Recording Stopped", properties: [
            "word_count": wordCount
        ])
    }

    func recordingError(error: String) {
        track("Phone Mic Recording Error", properties: [
            "error": error
        ])
    }

    // MARK: - Permission Events

    func permissionRequested(permission: String) {
        track("Permission Requested", properties: [
            "permission": permission
        ])
    }

    func permissionGranted(permission: String) {
        track("Permission Granted", properties: [
            "permission": permission
        ])
    }

    func permissionDenied(permission: String) {
        track("Permission Denied", properties: [
            "permission": permission
        ])
    }

    // MARK: - App Lifecycle Events

    func appLaunched() {
        track("App Launched", properties: [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString
        ])
    }

    func appBecameActive() {
        track("App Became Active")
    }

    func appResignedActive() {
        track("App Resigned Active")
    }

    // MARK: - Conversation Events
    // Note: The event is named "Memory Created" in Mixpanel for historical reasons,
    // but it actually tracks when a conversation/recording is created, not a "memory".
    // This matches Flutter's naming for analytics consistency.

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {
        var properties: [String: MixpanelType] = [
            "conversation_id": conversationId,
            "source": source
        ]
        if let duration = durationSeconds {
            properties["duration_seconds"] = duration
        }
        track("Memory Created", properties: properties)
    }

    func memoryDeleted(conversationId: String) {
        track("Memory Deleted", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryShareButtonClicked(conversationId: String) {
        track("Memory Share Button Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    func memoryListItemClicked(conversationId: String) {
        track("Memory List Item Clicked", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events

    func chatMessageSent(messageLength: Int, hasContext: Bool = false) {
        track("Chat Message Sent", properties: [
            "message_length": messageLength,
            "has_context": hasContext
        ])
    }

    // MARK: - Search Events

    func searchQueryEntered(query: String) {
        track("Search Query Entered", properties: [
            "query_length": query.count
        ])
    }

    func searchBarFocused() {
        track("Search Bar Focused")
    }

    // MARK: - Settings Events

    func settingsPageOpened() {
        track("Settings Page Opened")
    }

    // MARK: - Account Events

    func deleteAccountClicked() {
        track("Delete Account Clicked")
    }

    func deleteAccountConfirmed() {
        track("Delete Account Confirmed")
    }

    func deleteAccountCancelled() {
        track("Delete Account Cancelled")
    }
}
