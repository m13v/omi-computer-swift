import Cocoa
import UserNotifications

/// Service that manages proactive assistants - screen monitoring, frame capture, and assistant coordination
@MainActor
public class ProactiveAssistantsPlugin: NSObject {

    // MARK: - Singleton

    /// Shared instance
    public static let shared = ProactiveAssistantsPlugin()

    // MARK: - Properties

    private var screenCaptureService: ScreenCaptureService?
    private var windowMonitor: WindowMonitor?
    private var focusAssistant: FocusAssistant?
    private var taskAssistant: TaskAssistant?
    private var adviceAssistant: AdviceAssistant?
    private var captureTimer: Timer?
    private var analysisDelayTimer: Timer?
    private var isInDelayPeriod = false

    private(set) var isMonitoring = false
    private var _hasScreenRecordingPermission: Bool?  // Cached permission state
    private var currentApp: String?
    private var currentWindowID: CGWindowID?
    private var currentWindowTitle: String?
    private var lastStatus: FocusStatus?
    private var frameCount = 0

    // MARK: - Initialization

    private override init() {
        super.init()

        // Load environment variables
        loadEnvironment()

        // Set up the coordinator event callback
        AssistantCoordinator.shared.setEventCallback { [weak self] type, data in
            self?.sendEvent(type: type, data: data)
        }

        log("ProactiveAssistantsPlugin initialized")
    }

    // MARK: - Environment Loading

    private func loadEnvironment() {
        let envPaths = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            FileManager.default.currentDirectoryPath + "/.env",
            NSHomeDirectory() + "/.omi.env",
            NSHomeDirectory() + "/.hartford.env"
        ].compactMap { $0 }

        for path in envPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        setenv(key, value, 1)
                    }
                }
                log("Loaded environment from: \(path)")
                break
            }
        }
    }

    // MARK: - Assistant Management

    private func enableAssistant(identifier: String, enabled: Bool) {
        switch identifier {
        case "focus":
            FocusAssistantSettings.shared.isEnabled = enabled
        case "task-extraction":
            TaskAssistantSettings.shared.isEnabled = enabled
        case "advice":
            AdviceAssistantSettings.shared.isEnabled = enabled
        default:
            log("Unknown assistant: \(identifier)")
        }
    }

    // MARK: - Public Monitoring Control

    /// Start monitoring
    public func startMonitoring(completion: @escaping (Bool, String?) -> Void) {
        guard !isMonitoring else {
            completion(true, nil)
            return
        }

        // Check screen recording permission (and update cache)
        refreshScreenRecordingPermission()
        guard hasScreenRecordingPermission else {
            completion(false, "Screen recording permission not granted")
            return
        }

        // Request notification permission before starting
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(false, error.localizedDescription)
                    return
                }

                guard granted else {
                    completion(false, "Notification permission is required")
                    return
                }

                self?.continueStartMonitoring(completion: completion)
            }
        }
    }

    private func continueStartMonitoring(completion: @escaping (Bool, String?) -> Void) {
        // Initialize services
        screenCaptureService = ScreenCaptureService()

        do {
            focusAssistant = try FocusAssistant(
                onAlert: { [weak self] message in
                    self?.sendEvent(type: "alert", data: ["message": message])
                },
                onStatusChange: { [weak self] status in
                    Task { @MainActor in
                        self?.lastStatus = status
                        self?.sendEvent(type: "statusChange", data: ["status": status.rawValue])
                    }
                },
                onRefocus: {
                    Task { @MainActor in
                        OverlayService.shared.showGlowAroundActiveWindow(colorMode: .focused)
                    }
                },
                onDistraction: {
                    Task { @MainActor in
                        OverlayService.shared.showGlowAroundActiveWindow(colorMode: .distracted)
                    }
                }
            )

            if let focus = focusAssistant {
                AssistantCoordinator.shared.register(focus)
            }

            taskAssistant = try TaskAssistant()

            if let task = taskAssistant {
                AssistantCoordinator.shared.register(task)
            }

            adviceAssistant = try AdviceAssistant()

            if let advice = adviceAssistant {
                AssistantCoordinator.shared.register(advice)
            }

        } catch {
            completion(false, error.localizedDescription)
            return
        }

        // Get initial app state
        let (appName, _, _) = WindowMonitor.getActiveWindowInfoStatic()
        if let appName = appName {
            currentApp = appName
            AssistantCoordinator.shared.notifyAppSwitch(newApp: appName)
        }

        // Start window monitor
        windowMonitor = WindowMonitor { [weak self] appName in
            Task { @MainActor in
                self?.onAppActivated(appName: appName)
            }
        }
        windowMonitor?.start()

        // Start capture timer
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.captureFrame()
            }
        }

        isMonitoring = true

        NotificationService.shared.sendNotification(
            title: "OMI Assistants",
            message: "Monitoring started"
        )

        sendEvent(type: "monitoringStarted", data: [:])
        NotificationCenter.default.post(
            name: .assistantMonitoringStateDidChange,
            object: nil,
            userInfo: ["isMonitoring": true]
        )
        log("Proactive assistants started")

        completion(true, nil)
    }

    /// Stop monitoring
    public func stopMonitoring() {
        guard isMonitoring else { return }

        captureTimer?.invalidate()
        captureTimer = nil
        analysisDelayTimer?.invalidate()
        analysisDelayTimer = nil
        isInDelayPeriod = false

        windowMonitor?.stop()
        windowMonitor = nil

        if let focus = focusAssistant {
            Task {
                await focus.stop()
            }
        }
        if let task = taskAssistant {
            Task {
                await task.stop()
            }
        }
        if let advice = adviceAssistant {
            Task {
                await advice.stop()
            }
        }

        focusAssistant = nil
        taskAssistant = nil
        adviceAssistant = nil
        screenCaptureService = nil

        isMonitoring = false
        currentApp = nil
        currentWindowID = nil
        currentWindowTitle = nil
        lastStatus = nil
        frameCount = 0

        NotificationService.shared.sendNotification(
            title: "OMI Assistants",
            message: "Monitoring stopped"
        )

        sendEvent(type: "monitoringStopped", data: [:])
        NotificationCenter.default.post(
            name: .assistantMonitoringStateDidChange,
            object: nil,
            userInfo: ["isMonitoring": false]
        )
        log("Proactive assistants stopped")
    }

    /// Toggle monitoring state
    public func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring { success, error in
                if !success, let error = error {
                    logError("Failed to start monitoring: \(error)")
                }
            }
        }
    }

    /// Check if screen recording permission is granted
    /// Uses cached value to avoid excessive permission check logging
    public var hasScreenRecordingPermission: Bool {
        if let cached = _hasScreenRecordingPermission {
            return cached
        }
        // First access - check and cache
        let result = ScreenCaptureService.checkPermission()
        _hasScreenRecordingPermission = result
        return result
    }

    /// Refresh the cached screen recording permission state
    public func refreshScreenRecordingPermission() {
        _hasScreenRecordingPermission = ScreenCaptureService.checkPermission()
    }

    /// Get current monitoring status
    var currentStatus: (isMonitoring: Bool, currentApp: String?, lastStatus: FocusStatus?) {
        return (isMonitoring, currentApp, lastStatus)
    }

    // MARK: - Frame Capture

    private func onAppActivated(appName: String) {
        // Ignore our own app and system dialogs - don't monitor these (causes flickering)
        let ignoredApps = [
            "OMI-COMPUTER",           // Our own app
            "universalAccessAuthWarn", // macOS permission dialog
            "System Settings",         // System Settings app
            "System Preferences",      // Older macOS name
            "SecurityAgent",           // Security prompts
            "UserNotificationCenter"   // Notification center
        ]
        guard !ignoredApps.contains(appName) else { return }
        guard appName != currentApp else { return }
        currentApp = appName
        currentWindowID = nil
        currentWindowTitle = nil  // Reset window title on app switch

        // Notify all assistants
        AssistantCoordinator.shared.notifyAppSwitch(newApp: appName)

        sendEvent(type: "appSwitch", data: ["app": appName])

        // Start/restart the analysis delay timer
        let delaySeconds = AssistantSettings.shared.analysisDelay

        analysisDelayTimer?.invalidate()
        analysisDelayTimer = nil

        if delaySeconds > 0 {
            isInDelayPeriod = true
            AssistantCoordinator.shared.clearAllPendingWork()
            log("App switch detected, starting \(delaySeconds)s analysis delay")

            analysisDelayTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.isInDelayPeriod = false
                    self?.analysisDelayTimer = nil
                    log("Analysis delay ended, resuming frame processing")
                }
            }
        } else {
            isInDelayPeriod = false
            Task { @MainActor in
                await captureFrame()
            }
        }
    }

    private func captureFrame() async {
        guard isMonitoring, let screenCaptureService = screenCaptureService else { return }

        // Check for window switch and get window title
        let (_, windowTitle, windowID) = WindowMonitor.getActiveWindowInfoStatic()

        // Track window ID changes
        if let windowID = windowID, windowID != currentWindowID {
            let previousWindowID = currentWindowID
            currentWindowID = windowID

            if previousWindowID != nil {
                onWindowSwitch(windowID: windowID)
            }
        }

        // Track window title changes (e.g., browser tab switches)
        if windowTitle != currentWindowTitle {
            if let title = windowTitle, let oldTitle = currentWindowTitle {
                log("Window title changed: '\(oldTitle)' → '\(title)'")
            }
            currentWindowTitle = windowTitle
        }

        // Always capture frames (other features may need them)
        if let jpegData = await screenCaptureService.captureActiveWindowAsync(),
           let appName = currentApp {
            frameCount += 1

            let frame = CapturedFrame(
                jpegData: jpegData,
                appName: appName,
                windowTitle: currentWindowTitle,
                frameNumber: frameCount
            )

            // Only distribute to assistants if not in delay period
            if !isInDelayPeriod {
                AssistantCoordinator.shared.distributeFrame(frame)
            }
        }
    }

    private func onWindowSwitch(windowID: CGWindowID) {
        let delaySeconds = AssistantSettings.shared.analysisDelay

        guard delaySeconds > 0 else { return }

        analysisDelayTimer?.invalidate()
        analysisDelayTimer = nil

        isInDelayPeriod = true
        AssistantCoordinator.shared.clearAllPendingWork()
        log("Window switch detected (ID: \(windowID)), starting \(delaySeconds)s analysis delay")

        analysisDelayTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isInDelayPeriod = false
                self?.analysisDelayTimer = nil
                log("Analysis delay ended, resuming frame processing")
            }
        }
    }

    // MARK: - Event Broadcasting

    private func sendEvent(type: String, data: [String: Any]) {
        var event = data
        event["type"] = type
        event["timestamp"] = ISO8601DateFormatter().string(from: Date())

        // Post notification for any listeners
        NotificationCenter.default.post(
            name: .assistantEvent,
            object: nil,
            userInfo: event
        )
    }

    // MARK: - Utility Methods

    /// Open screen recording preferences
    public func openScreenRecordingPreferences() {
        ScreenCaptureService.openScreenRecordingPreferences()
    }

    /// Trigger glow effect manually (for testing)
    func triggerGlow(colorMode: GlowColorMode = .focused) {
        OverlayService.shared.showGlowAroundActiveWindow(colorMode: colorMode)
    }

    /// Show settings window
    public func showSettings() {
        SettingsWindow.show()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let assistantEvent = Notification.Name("assistantEvent")
}

// MARK: - Backward Compatibility Alias

typealias FocusPlugin = ProactiveAssistantsPlugin
typealias MonitoringService = ProactiveAssistantsPlugin
