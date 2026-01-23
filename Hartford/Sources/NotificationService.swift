import Foundation
import UserNotifications

class NotificationService {
    static let shared = NotificationService()

    private var lastNotificationTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 120.0

    private init() {}

    func sendNotification(title: String, message: String, applyCooldown: Bool = true) {
        if applyCooldown {
            let timeSinceLast = Date().timeIntervalSince(lastNotificationTime)
            if timeSinceLast < cooldownSeconds {
                let remaining = cooldownSeconds - timeSinceLast
                log("Notification in cooldown (\(String(format: "%.1f", remaining))s remaining), skipping: \(message)")
                return
            }
            lastNotificationTime = Date()
        }

        let content = UNMutableNotificationContent()
        content.title = "OMI"
        content.subtitle = title
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log("Notification error: \(error)")
            }
        }
    }
}
