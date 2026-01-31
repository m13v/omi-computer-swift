import Foundation
import UserNotifications

@MainActor
class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Category ID for notifications that track dismissal
    private static let trackableCategoryId = "omi.trackable"

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

        UNUserNotificationCenter.current().setNotificationCategories([trackableCategory])
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

            case UNNotificationDismissActionIdentifier:
                // User explicitly dismissed the notification (X button, swipe, or Clear)
                print("[\(assistantId)] Notification dismissed: \(title)")
                AnalyticsManager.shared.notificationDismissed(
                    notificationId: notificationId,
                    title: title,
                    assistantId: assistantId
                )

            default:
                // Custom action (if we add action buttons in the future)
                print("[\(assistantId)] Notification action: \(response.actionIdentifier)")
            }

            // Clean up metadata
            self.notificationMetadata.removeValue(forKey: notificationId)
        }

        completionHandler()
    }

    func sendNotification(title: String, message: String, assistantId: String = "default") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = .default
        content.categoryIdentifier = Self.trackableCategoryId  // Enable dismiss tracking

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
