import Foundation
import PostHog
import FirebaseAuth

/// Singleton manager for PostHog analytics with Session Replay
/// Complements MixpanelManager - both track the same events
@MainActor
class PostHogManager {
    static let shared = PostHogManager()

    private var isInitialized = false

    // PostHog configuration
    private let apiKey = "phc_z3qUFhGUgYIOMYnfxVSrLmYISQvbgph8iREQv3sez3Y"
    private let host = "https://us.i.posthog.com"

    private init() {}

    // MARK: - Initialization

    /// Initialize PostHog with analytics and session replay
    func initialize() {
        guard !isInitialized else { return }

        let config = PostHogConfig(apiKey: apiKey, host: host)

        // Enable automatic event capture
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = true

        // Enable Session Replay (iOS/macOS)
        // Note: Session replay on mobile captures screenshots periodically
        config.sessionReplay = true
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = false

        PostHogSDK.shared.setup(config)

        isInitialized = true
        log("PostHog: Initialized successfully")
    }

    // MARK: - User Identification

    /// Identify the current user after sign-in
    func identify() {
        guard isInitialized else { return }

        guard let user = Auth.auth().currentUser else {
            log("PostHog: Cannot identify - no user signed in")
            return
        }

        var properties: [String: Any] = [
            "platform": "macos",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        ]

        if let email = user.email {
            properties["email"] = email
        }

        if let name = user.displayName {
            properties["name"] = name
        }

        PostHogSDK.shared.identify(user.uid, userProperties: properties)
        log("PostHog: Identified user \(user.uid)")
    }

    /// Set a specific user property
    func setUserProperty(key: String, value: Any) {
        guard isInitialized else { return }
        PostHogSDK.shared.identify(PostHogSDK.shared.getDistinctId(), userProperties: [key: value])
    }

    // MARK: - Event Tracking

    /// Track an event with optional properties
    func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard isInitialized else { return }
        PostHogSDK.shared.capture(eventName, properties: properties)
        log("PostHog: Tracked event '\(eventName)'")
    }

    // MARK: - Screen Tracking

    /// Track a screen view
    func screen(_ screenName: String, properties: [String: Any]? = nil) {
        guard isInitialized else { return }
        PostHogSDK.shared.screen(screenName, properties: properties)
    }

    // MARK: - Opt In/Out

    /// Opt in to tracking
    func optIn() {
        guard isInitialized else { return }
        PostHogSDK.shared.optIn()
    }

    /// Opt out of tracking
    func optOut() {
        guard isInitialized else { return }
        PostHogSDK.shared.optOut()
    }

    /// Check if tracking is opted out
    var hasOptedOut: Bool {
        guard isInitialized else { return true }
        return !PostHogSDK.shared.isOptOut()
    }

    // MARK: - Reset

    /// Reset the user (call on sign out)
    func reset() {
        guard isInitialized else { return }
        PostHogSDK.shared.reset()
        log("PostHog: Reset user")
    }

    // MARK: - Feature Flags

    /// Check if a feature flag is enabled
    func isFeatureEnabled(_ flag: String) -> Bool {
        guard isInitialized else { return false }
        return PostHogSDK.shared.isFeatureEnabled(flag)
    }

    /// Get feature flag value
    func getFeatureFlag(_ flag: String) -> Any? {
        guard isInitialized else { return nil }
        return PostHogSDK.shared.getFeatureFlag(flag)
    }

    /// Reload feature flags
    func reloadFeatureFlags() {
        guard isInitialized else { return }
        PostHogSDK.shared.reloadFeatureFlags()
    }
}

// MARK: - Analytics Events

extension PostHogManager {

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {
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
        track("Monitoring Started")
    }

    func monitoringStopped() {
        track("Monitoring Stopped")
    }

    func distractionDetected(app: String, windowTitle: String?) {
        var properties: [String: Any] = [
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

    // MARK: - Recording Events

    func transcriptionStarted() {
        track("Phone Mic Recording Started")
    }

    func transcriptionStopped(wordCount: Int) {
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

    // MARK: - Page/Screen Views (PostHog specific)

    func pageViewed(_ pageName: String) {
        screen(pageName)
        track("Page Viewed", properties: ["page": pageName])
    }
}
