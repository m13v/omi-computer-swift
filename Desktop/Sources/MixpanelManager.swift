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

    /// Track first launch with comprehensive system diagnostics
    func firstLaunch(diagnostics: [String: Any]) {
        // Convert to MixpanelType dictionary
        var mixpanelProperties: [String: MixpanelType] = [:]
        for (key, value) in diagnostics {
            if let stringValue = value as? String {
                mixpanelProperties[key] = stringValue
            } else if let intValue = value as? Int {
                mixpanelProperties[key] = intValue
            } else if let boolValue = value as? Bool {
                mixpanelProperties[key] = boolValue
            } else if let doubleValue = value as? Double {
                mixpanelProperties[key] = doubleValue
            }
        }
        track("First Launch", properties: mixpanelProperties)
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

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {
        track("Tab Changed", properties: [
            "tab_name": tabName
        ])
    }

    func conversationDetailOpened(conversationId: String) {
        track("Conversation Detail Opened", properties: [
            "conversation_id": conversationId
        ])
    }

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {
        var properties: [String: MixpanelType] = [:]
        if let id = appId { properties["app_id"] = id }
        if let name = appName { properties["app_name"] = name }
        track("Chat App Selected", properties: properties.isEmpty ? nil : properties)
    }

    func chatCleared() {
        track("Chat Cleared")
    }

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {
        track("Conversation Reprocessed", properties: [
            "conversation_id": conversationId,
            "app_id": appId
        ])
    }

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {
        track("Setting Toggled", properties: [
            "setting": setting,
            "enabled": enabled
        ])
    }

    func languageChanged(language: String) {
        track("Language Changed", properties: [
            "language": language
        ])
    }

    // MARK: - Feedback Events

    func feedbackOpened() {
        track("Feedback Opened")
    }

    func feedbackSubmitted(feedbackLength: Int) {
        track("Feedback Submitted", properties: [
            "feedback_length": feedbackLength
        ])
    }

    // MARK: - Rewind Events (Desktop-specific)

    func rewindSearchPerformed(queryLength: Int) {
        track("Rewind Search Performed", properties: [
            "query_length": queryLength
        ])
    }

    func rewindScreenshotViewed(timestamp: Date) {
        track("Rewind Screenshot Viewed", properties: [
            "timestamp": ISO8601DateFormatter().string(from: timestamp)
        ])
    }

    func rewindTimelineNavigated(direction: String) {
        track("Rewind Timeline Navigated", properties: [
            "direction": direction
        ])
    }

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {
        track("Focus Alert Shown", properties: [
            "app": app
        ])
    }

    func focusAlertDismissed(app: String, action: String) {
        track("Focus Alert Dismissed", properties: [
            "app": app,
            "action": action
        ])
    }

    func taskExtracted(taskCount: Int) {
        track("Task Extracted", properties: [
            "task_count": taskCount
        ])
    }

    func memoryExtracted(memoryCount: Int) {
        track("Memory Extracted", properties: [
            "memory_count": memoryCount
        ])
    }

    func adviceGenerated(category: String?) {
        var properties: [String: MixpanelType] = [:]
        if let cat = category { properties["category"] = cat }
        track("Advice Generated", properties: properties.isEmpty ? nil : properties)
    }

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {
        track("App Enabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDisabled(appId: String, appName: String) {
        track("App Disabled", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    func appDetailViewed(appId: String, appName: String) {
        track("App Detail Viewed", properties: [
            "app_id": appId,
            "app_name": appName
        ])
    }

    // MARK: - Update Events

    func updateCheckStarted() {
        track("Update Check Started")
    }

    func updateAvailable(version: String) {
        track("Update Available", properties: [
            "version": version
        ])
    }

    func updateInstalled(version: String) {
        track("Update Installed", properties: [
            "version": version
        ])
    }
}
