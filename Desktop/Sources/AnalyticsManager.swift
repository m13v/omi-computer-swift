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

    // MARK: - Navigation Events

    func tabChanged(tabName: String) {
        MixpanelManager.shared.tabChanged(tabName: tabName)
        PostHogManager.shared.tabChanged(tabName: tabName)
    }

    func conversationDetailOpened(conversationId: String) {
        MixpanelManager.shared.conversationDetailOpened(conversationId: conversationId)
        PostHogManager.shared.conversationDetailOpened(conversationId: conversationId)
    }

    // MARK: - Chat Events (Additional)

    func chatAppSelected(appId: String?, appName: String?) {
        MixpanelManager.shared.chatAppSelected(appId: appId, appName: appName)
        PostHogManager.shared.chatAppSelected(appId: appId, appName: appName)
    }

    func chatCleared() {
        MixpanelManager.shared.chatCleared()
        PostHogManager.shared.chatCleared()
    }

    // MARK: - Conversation Events (Additional)

    func conversationReprocessed(conversationId: String, appId: String) {
        MixpanelManager.shared.conversationReprocessed(conversationId: conversationId, appId: appId)
        PostHogManager.shared.conversationReprocessed(conversationId: conversationId, appId: appId)
    }

    // MARK: - Settings Events (Additional)

    func settingToggled(setting: String, enabled: Bool) {
        MixpanelManager.shared.settingToggled(setting: setting, enabled: enabled)
        PostHogManager.shared.settingToggled(setting: setting, enabled: enabled)
    }

    func languageChanged(language: String) {
        MixpanelManager.shared.languageChanged(language: language)
        PostHogManager.shared.languageChanged(language: language)
    }

    // MARK: - Feedback Events

    func feedbackOpened() {
        MixpanelManager.shared.feedbackOpened()
        PostHogManager.shared.feedbackOpened()
    }

    func feedbackSubmitted(feedbackLength: Int) {
        MixpanelManager.shared.feedbackSubmitted(feedbackLength: feedbackLength)
        PostHogManager.shared.feedbackSubmitted(feedbackLength: feedbackLength)
    }

    // MARK: - Rewind Events (Desktop-specific)

    func rewindSearchPerformed(queryLength: Int) {
        MixpanelManager.shared.rewindSearchPerformed(queryLength: queryLength)
        PostHogManager.shared.rewindSearchPerformed(queryLength: queryLength)
    }

    func rewindScreenshotViewed(timestamp: Date) {
        MixpanelManager.shared.rewindScreenshotViewed(timestamp: timestamp)
        PostHogManager.shared.rewindScreenshotViewed(timestamp: timestamp)
    }

    func rewindTimelineNavigated(direction: String) {
        MixpanelManager.shared.rewindTimelineNavigated(direction: direction)
        PostHogManager.shared.rewindTimelineNavigated(direction: direction)
    }

    // MARK: - Proactive Assistant Events (Desktop-specific)

    func focusAlertShown(app: String) {
        MixpanelManager.shared.focusAlertShown(app: app)
        PostHogManager.shared.focusAlertShown(app: app)
    }

    func focusAlertDismissed(app: String, action: String) {
        MixpanelManager.shared.focusAlertDismissed(app: app, action: action)
        PostHogManager.shared.focusAlertDismissed(app: app, action: action)
    }

    func taskExtracted(taskCount: Int) {
        MixpanelManager.shared.taskExtracted(taskCount: taskCount)
        PostHogManager.shared.taskExtracted(taskCount: taskCount)
    }

    func memoryExtracted(memoryCount: Int) {
        MixpanelManager.shared.memoryExtracted(memoryCount: memoryCount)
        PostHogManager.shared.memoryExtracted(memoryCount: memoryCount)
    }

    func adviceGenerated(category: String?) {
        MixpanelManager.shared.adviceGenerated(category: category)
        PostHogManager.shared.adviceGenerated(category: category)
    }

    // MARK: - Apps Events

    func appEnabled(appId: String, appName: String) {
        MixpanelManager.shared.appEnabled(appId: appId, appName: appName)
        PostHogManager.shared.appEnabled(appId: appId, appName: appName)
    }

    func appDisabled(appId: String, appName: String) {
        MixpanelManager.shared.appDisabled(appId: appId, appName: appName)
        PostHogManager.shared.appDisabled(appId: appId, appName: appName)
    }

    func appDetailViewed(appId: String, appName: String) {
        MixpanelManager.shared.appDetailViewed(appId: appId, appName: appName)
        PostHogManager.shared.appDetailViewed(appId: appId, appName: appName)
    }

    // MARK: - Update Events

    func updateCheckStarted() {
        MixpanelManager.shared.updateCheckStarted()
        PostHogManager.shared.updateCheckStarted()
    }

    func updateAvailable(version: String) {
        MixpanelManager.shared.updateAvailable(version: version)
        PostHogManager.shared.updateAvailable(version: version)
    }

    func updateInstalled(version: String) {
        MixpanelManager.shared.updateInstalled(version: version)
        PostHogManager.shared.updateInstalled(version: version)
    }
}
