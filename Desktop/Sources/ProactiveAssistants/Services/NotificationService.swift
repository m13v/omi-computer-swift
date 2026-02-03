import Foundation
import UserNotifications

/// Sound options for notifications
enum NotificationSound {
    case `default`
    case focusLost
    case focusRegained
    case none

    var unSound: UNNotificationSound? {
        switch self {
        case .default:
            return .default
        case .focusLost:
            return UNNotificationSound(named: UNNotificationSoundName("focus-lost.aiff"))
        case .focusRegained:
            return UNNotificationSound(named: UNNotificationSoundName("focus-regained.aiff"))
        case .none:
            return nil
        }
    }
}

@MainActor
class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Category ID for notifications that track dismissal
    private static let trackableCategoryId = "omi.trackable"

    /// Category ID for screen capture reset notifications with action button
    private static let screenCaptureResetCategoryId = "omi.screen_capture_reset"

    /// Action ID for the "Reset Now" button
    private static let resetNowActionId = "RESET_SCREEN_CAPTURE_NOW"

    /// Title that identifies screen capture reset notifications
    static let screenCaptureResetTitle = "Screen Recording Needs Reset"

    /// Stores metadata for sent notifications so we can retrieve it in delegate callbacks
    /// Key: notification identifier, Value: (title, assistantId)
    private var notificationMetadata: [String: (title: String, assistantId: String)] = [:]

    private override init() {
        super.init()
        // Set ourselves as the delegate to show notifications even when app is in foreground
        UNUserNotificationCenter.current().delegate = self
        // Set up notification categories for tracking
        setupNotificationCategories()
    }

    /// Set up notification categories to enable dismiss tracking
    private func setupNotificationCategories() {
        // Create a category that tracks custom dismiss action
        // This allows us to know when a user explicitly dismisses a notification
        let trackableCategory = UNNotificationCategory(
            identifier: Self.trackableCategoryId,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]  // This enables didReceive callback on dismiss
        )

        // Create "Reset Now" action for screen capture reset notifications
        let resetNowAction = UNNotificationAction(
            identifier: Self.resetNowActionId,
            title: "Reset Now",
            options: [.foreground]  // Bring app to foreground when tapped
        )

        // Create category for screen capture reset with the action button
        let screenCaptureResetCategory = UNNotificationCategory(
            identifier: Self.screenCaptureResetCategoryId,
            actions: [resetNowAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([trackableCategory, screenCaptureResetCategory])
    }

    // MARK: - UNUserNotificationCenterDelegate

    // This allows notifications to be displayed even when the app is in the foreground
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show banner, play sound, and update badge even when app is frontmost
        completionHandler([.banner, .sound, .badge])
    }

    // Handle notification interactions (click or dismiss)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let notificationId = response.notification.request.identifier

        Task { @MainActor in
            // Retrieve stored metadata
            let metadata = self.notificationMetadata[notificationId]
            let title = metadata?.title ?? response.notification.request.content.title
            let assistantId = metadata?.assistantId ?? "unknown"

            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                // User clicked/tapped the notification
                print("[\(assistantId)] Notification clicked: \(title)")
                AnalyticsManager.shared.notificationClicked(
                    notificationId: notificationId,
                    title: title,
                    assistantId: assistantId
                )

                // If this is a screen capture reset notification, trigger the reset
                if title == Self.screenCaptureResetTitle {
                    self.handleScreenCaptureResetAction(source: "notification_click")
                }

            case UNNotificationDismissActionIdentifier:
                // User explicitly dismissed the notification (X button, swipe, or Clear)
                print("[\(assistantId)] Notification dismissed: \(title)")
                AnalyticsManager.shared.notificationDismissed(
                    notificationId: notificationId,
                    title: title,
                    assistantId: assistantId
                )

            case Self.resetNowActionId:
                // User clicked the "Reset Now" action button
                print("[\(assistantId)] Reset Now action clicked: \(title)")
                AnalyticsManager.shared.notificationClicked(
                    notificationId: notificationId,
                    title: title,
                    assistantId: assistantId
                )
                self.handleScreenCaptureResetAction(source: "notification_action_button")

            default:
                // Custom action (if we add action buttons in the future)
                print("[\(assistantId)] Notification action: \(response.actionIdentifier)")
            }

            // Clean up metadata
            self.notificationMetadata.removeValue(forKey: notificationId)
        }

        completionHandler()
    }

    /// Handle screen capture reset action from notification click or action button
    private func handleScreenCaptureResetAction(source: String) {
        log("Screen capture reset triggered from \(source)")
        AnalyticsManager.shared.screenCaptureResetClicked(source: source)
        ScreenCaptureService.resetScreenCapturePermissionAndRestart()
    }

    func sendNotification(title: String, message: String, assistantId: String = "default", sound: NotificationSound = .default) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = sound.unSound

        // Use screen capture reset category for reset notifications (adds "Reset Now" button)
        if title == Self.screenCaptureResetTitle {
            content.categoryIdentifier = Self.screenCaptureResetCategoryId
        } else {
            content.categoryIdentifier = Self.trackableCategoryId  // Enable dismiss tracking
        }

        let notificationId = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil // Deliver immediately
        )

        // Store metadata for later retrieval in delegate callbacks
        notificationMetadata[notificationId] = (title: title, assistantId: assistantId)

        print("[\(assistantId)] Sending notification: \(title) - \(message)")
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error = error {
                print("Notification error: \(error)")
                logError("Notification error", error: error)
                // Clean up metadata on error
                Task { @MainActor in
                    self?.notificationMetadata.removeValue(forKey: notificationId)
                }
            } else {
                print("Notification sent successfully")
                // Track notification sent
                Task { @MainActor in
                    AnalyticsManager.shared.notificationSent(
                        notificationId: notificationId,
                        title: title,
                        assistantId: assistantId
                    )
                }
            }
        }
    }
}
