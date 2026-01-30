import Foundation

/// Unified analytics manager that sends events to both Mixpanel and PostHog
/// Use this instead of calling MixpanelManager and PostHogManager directly
@MainActor
class AnalyticsManager {
    static let shared = AnalyticsManager()

    private init() {}

    // MARK: - Initialization

    func initialize() {
        MixpanelManager.shared.initialize()
        PostHogManager.shared.initialize()
    }

    // MARK: - User Identification

    func identify() {
        MixpanelManager.shared.identify()
        PostHogManager.shared.identify()
    }

    func reset() {
        MixpanelManager.shared.reset()
        PostHogManager.shared.reset()
    }

    // MARK: - Opt In/Out

    func optInTracking() {
        MixpanelManager.shared.optInTracking()
        PostHogManager.shared.optIn()
    }

    func optOutTracking() {
        MixpanelManager.shared.optOutTracking()
        PostHogManager.shared.optOut()
    }

    // MARK: - Onboarding Events

    func onboardingStepCompleted(step: Int, stepName: String) {
        MixpanelManager.shared.onboardingStepCompleted(step: step, stepName: stepName)
        PostHogManager.shared.onboardingStepCompleted(step: step, stepName: stepName)
    }

    func onboardingCompleted() {
        MixpanelManager.shared.onboardingCompleted()
        PostHogManager.shared.onboardingCompleted()
    }

    // MARK: - Authentication Events

    func signInStarted(provider: String) {
        MixpanelManager.shared.signInStarted(provider: provider)
        PostHogManager.shared.signInStarted(provider: provider)
    }

    func signInCompleted(provider: String) {
        MixpanelManager.shared.signInCompleted(provider: provider)
        PostHogManager.shared.signInCompleted(provider: provider)
    }

    func signInFailed(provider: String, error: String) {
        MixpanelManager.shared.signInFailed(provider: provider, error: error)
        PostHogManager.shared.signInFailed(provider: provider, error: error)
    }

    func signedOut() {
        MixpanelManager.shared.signedOut()
        PostHogManager.shared.signedOut()
    }

    // MARK: - Monitoring Events

    func monitoringStarted() {
        MixpanelManager.shared.monitoringStarted()
        PostHogManager.shared.monitoringStarted()
    }

    func monitoringStopped() {
        MixpanelManager.shared.monitoringStopped()
        PostHogManager.shared.monitoringStopped()
    }

    func distractionDetected(app: String, windowTitle: String?) {
        MixpanelManager.shared.distractionDetected(app: app, windowTitle: windowTitle)
        PostHogManager.shared.distractionDetected(app: app, windowTitle: windowTitle)
    }

    func focusRestored(app: String) {
        MixpanelManager.shared.focusRestored(app: app)
        PostHogManager.shared.focusRestored(app: app)
    }

    // MARK: - Recording Events

    func transcriptionStarted() {
        MixpanelManager.shared.transcriptionStarted()
        PostHogManager.shared.transcriptionStarted()
    }

    func transcriptionStopped(wordCount: Int) {
        MixpanelManager.shared.transcriptionStopped(wordCount: wordCount)
        PostHogManager.shared.transcriptionStopped(wordCount: wordCount)
    }

    func recordingError(error: String) {
        MixpanelManager.shared.recordingError(error: error)
        PostHogManager.shared.recordingError(error: error)
    }

    // MARK: - Permission Events

    func permissionRequested(permission: String) {
        MixpanelManager.shared.permissionRequested(permission: permission)
        PostHogManager.shared.permissionRequested(permission: permission)
    }

    func permissionGranted(permission: String) {
        MixpanelManager.shared.permissionGranted(permission: permission)
        PostHogManager.shared.permissionGranted(permission: permission)
    }

    func permissionDenied(permission: String) {
        MixpanelManager.shared.permissionDenied(permission: permission)
        PostHogManager.shared.permissionDenied(permission: permission)
    }

    // MARK: - App Lifecycle Events

    func appLaunched() {
        MixpanelManager.shared.appLaunched()
        PostHogManager.shared.appLaunched()
    }

    func appBecameActive() {
        MixpanelManager.shared.appBecameActive()
        PostHogManager.shared.appBecameActive()
    }

    func appResignedActive() {
        MixpanelManager.shared.appResignedActive()
        PostHogManager.shared.appResignedActive()
    }

    // MARK: - Conversation Events
    // Note: The event is named "Memory Created" in analytics for historical reasons,
    // but it actually tracks when a conversation/recording is created, not a "memory".

    func conversationCreated(conversationId: String, source: String, durationSeconds: Int? = nil) {
        MixpanelManager.shared.conversationCreated(conversationId: conversationId, source: source, durationSeconds: durationSeconds)
        PostHogManager.shared.conversationCreated(conversationId: conversationId, source: source, durationSeconds: durationSeconds)
    }

    func memoryDeleted(conversationId: String) {
        MixpanelManager.shared.memoryDeleted(conversationId: conversationId)
        PostHogManager.shared.memoryDeleted(conversationId: conversationId)
    }

    func memoryShareButtonClicked(conversationId: String) {
        MixpanelManager.shared.memoryShareButtonClicked(conversationId: conversationId)
        PostHogManager.shared.memoryShareButtonClicked(conversationId: conversationId)
    }

    func memoryListItemClicked(conversationId: String) {
        MixpanelManager.shared.memoryListItemClicked(conversationId: conversationId)
        PostHogManager.shared.memoryListItemClicked(conversationId: conversationId)
    }

    // MARK: - Chat Events

    func chatMessageSent(messageLength: Int, hasContext: Bool = false) {
        MixpanelManager.shared.chatMessageSent(messageLength: messageLength, hasContext: hasContext)
        PostHogManager.shared.chatMessageSent(messageLength: messageLength, hasContext: hasContext)
    }

    // MARK: - Search Events

    func searchQueryEntered(query: String) {
        MixpanelManager.shared.searchQueryEntered(query: query)
        PostHogManager.shared.searchQueryEntered(query: query)
    }

    func searchBarFocused() {
        MixpanelManager.shared.searchBarFocused()
        PostHogManager.shared.searchBarFocused()
    }

    // MARK: - Settings Events

    func settingsPageOpened() {
        MixpanelManager.shared.settingsPageOpened()
        PostHogManager.shared.settingsPageOpened()
    }

    // MARK: - Page/Screen Views (PostHog specific, but tracked in both)

    func pageViewed(_ pageName: String) {
        PostHogManager.shared.pageViewed(pageName)
        // Mixpanel doesn't have a dedicated screen view, but we track as an event
        MixpanelManager.shared.track("Page Viewed", properties: ["page": pageName])
    }

    // MARK: - Account Events

    func deleteAccountClicked() {
        MixpanelManager.shared.deleteAccountClicked()
        PostHogManager.shared.deleteAccountClicked()
    }

    func deleteAccountConfirmed() {
        MixpanelManager.shared.deleteAccountConfirmed()
        PostHogManager.shared.deleteAccountConfirmed()
    }

    func deleteAccountCancelled() {
        MixpanelManager.shared.deleteAccountCancelled()
        PostHogManager.shared.deleteAccountCancelled()
    }
}
