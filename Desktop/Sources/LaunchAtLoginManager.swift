import Foundation
import ServiceManagement

/// Manages the app's launch at login status using SMAppService (macOS 13+)
@MainActor
class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled: Bool = false

    private init() {
        // Check current status on init
        updateStatus()
    }

    /// Updates the published status from the system
    func updateStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Enables or disables launch at login
    /// - Parameter enabled: Whether the app should launch at login
    /// - Returns: true if the operation succeeded
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log("LaunchAtLogin: Successfully registered for launch at login")
            } else {
                try SMAppService.mainApp.unregister()
                log("LaunchAtLogin: Successfully unregistered from launch at login")
            }
            updateStatus()
            return true
        } catch {
            log("LaunchAtLogin: Failed to \(enabled ? "register" : "unregister"): \(error.localizedDescription)")
            updateStatus()
            return false
        }
    }

    /// Human-readable status description
    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "App will start when you log in"
        case .notRegistered:
            return "App won't start automatically"
        case .notFound:
            return "Login item not found"
        case .requiresApproval:
            return "Requires approval in System Settings"
        @unknown default:
            return "Unknown status"
        }
    }
}
