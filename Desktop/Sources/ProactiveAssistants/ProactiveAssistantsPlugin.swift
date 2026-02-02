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
    private var memoryAssistant: MemoryAssistant?
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

    // Failure tracking for screen capture recovery
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 5
    private var lastCaptureSucceeded = true
    private var wasMonitoringBeforeSleep = false
    private var wasMonitoringBeforeLock = false
    private var systemEventObservers: [NSObjectProtocol] = []

    // MARK: - Initialization

    private override init() {
        super.init()

        // Load environment variables
        loadEnvironment()

        // Set up the coordinator event callback
        AssistantCoordinator.shared.setEventCallback { [weak self] type, data in
            self?.sendEvent(type: type, data: data)
        }

        // Set up system event observers for sleep/wake/lock recovery
        setupSystemEventObservers()

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
        case "memory-extraction":
            MemoryAssistantSettings.shared.isEnabled = enabled
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
        // Report resources before starting heavy monitoring
        ResourceMonitor.shared.reportResourcesNow(context: "before_monitoring_start")

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

            memoryAssistant = try MemoryAssistant()

            if let memory = memoryAssistant {
                AssistantCoordinator.shared.register(memory)
            }

        } catch {
            completion(false, error.localizedDescription)
            return
        }

        // Get initial app state
        let (appName, _, _) = WindowMonitor.getActiveWindowInfoStatic()
        if let appName = appName {
            currentApp = appName
            // Update FocusStorage with initial detected app
            FocusStorage.shared.updateDetectedApp(appName)
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

        // Report resources after initialization
        ResourceMonitor.shared.reportResourcesNow(context: "after_monitoring_start")

        NotificationService.shared.sendNotification(
            title: "Omi Assistants",
            message: "Monitoring started"
        )

        sendEvent(type: "monitoringStarted", data: [:])
        AnalyticsManager.shared.monitoringStarted()
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
        if let memory = memoryAssistant {
            Task {
                await memory.stop()
            }
        }

        focusAssistant = nil
        taskAssistant = nil
        adviceAssistant = nil
        memoryAssistant = nil
        screenCaptureService = nil

        isMonitoring = false
        currentApp = nil
        currentWindowID = nil
        currentWindowTitle = nil
        lastStatus = nil
        frameCount = 0

        // Clear FocusStorage real-time state
        FocusStorage.shared.clearRealtimeStatus()

        // Report resources after stopping
        ResourceMonitor.shared.reportResourcesNow(context: "after_monitoring_stop")

        NotificationService.shared.sendNotification(
            title: "Omi Assistants",
            message: "Monitoring stopped"
        )

        sendEvent(type: "monitoringStopped", data: [:])
        AnalyticsManager.shared.monitoringStopped()
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
        guard appName != currentApp else { return }
        currentApp = appName
        currentWindowID = nil
        currentWindowTitle = nil  // Reset window title on app switch

        // Update FocusStorage immediately with detected app (before analysis)
        FocusStorage.shared.updateDetectedApp(appName)

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

            // Update FocusStorage with delay end time
            let delayEndTime = Date().addingTimeInterval(TimeInterval(delaySeconds))
            FocusStorage.shared.updateDelayEndTime(delayEndTime)

            analysisDelayTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.isInDelayPeriod = false
                    self?.analysisDelayTimer = nil
                    FocusStorage.shared.updateDelayEndTime(nil)
                    log("Analysis delay ended, resuming frame processing")
                }
            }
        } else {
            isInDelayPeriod = false
            FocusStorage.shared.updateDelayEndTime(nil)
            Task { @MainActor in
                await captureFrame()
            }
        }
    }

    private func captureFrame() async {
        guard isMonitoring, let screenCaptureService = screenCaptureService else { return }

        // Get current window info (use real app name, not cached)
        let (realAppName, windowTitle, windowID) = WindowMonitor.getActiveWindowInfoStatic()

        // Check if the current app is excluded from capture
        if let appName = realAppName, RewindSettings.shared.isAppExcluded(appName) {
            return
        }

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

        // Use real app name from window info, fall back to cached if unavailable
        let appName = realAppName ?? currentApp

        // Always capture frames (other features may need them)
        if let jpegData = await screenCaptureService.captureActiveWindowAsync(),
           let appName = appName {
            // Reset failure counter on success
            if !lastCaptureSucceeded {
                log("Screen capture recovered after \(consecutiveFailures) failures")
            }
            consecutiveFailures = 0
            lastCaptureSucceeded = true

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

            // Store frame for Rewind search (independent of delay period)
            Task {
                await RewindIndexer.shared.processFrame(frame)
            }
        } else {
            // Track capture failures
            consecutiveFailures += 1
            lastCaptureSucceeded = false

            if consecutiveFailures >= maxConsecutiveFailures {
                handleRepeatedCaptureFailures()
            }
        }
    }

    private func onWindowSwitch(windowID: CGWindowID) {
        let delaySeconds = AssistantSettings.shared.analysisDelay

        guard delaySeconds > 0 else { return }

        // Don't reset the delay if we're already in a delay period
        // This prevents the timer from constantly resetting on rapid window changes
        if isInDelayPeriod {
            log("Window switch detected (ID: \(windowID)), but already in delay period - ignoring")
            return
        }

        analysisDelayTimer?.invalidate()
        analysisDelayTimer = nil

        isInDelayPeriod = true
        AssistantCoordinator.shared.clearAllPendingWork()
        log("Window switch detected (ID: \(windowID)), starting \(delaySeconds)s analysis delay")

        // Update FocusStorage with delay end time
        let delayEndTime = Date().addingTimeInterval(TimeInterval(delaySeconds))
        FocusStorage.shared.updateDelayEndTime(delayEndTime)

        analysisDelayTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.isInDelayPeriod = false
                self?.analysisDelayTimer = nil
                FocusStorage.shared.updateDelayEndTime(nil)
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

    // MARK: - System Event Handling

    /// Set up observers for system sleep/wake and screen lock/unlock events
    private func setupSystemEventObservers() {
        // System about to sleep - track state before sleep
        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.wasMonitoringBeforeSleep = self?.isMonitoring ?? false
                log("ProactiveAssistantsPlugin: System going to sleep, wasMonitoring=\(self?.wasMonitoringBeforeSleep ?? false)")
            }
        }
        systemEventObservers.append(sleepObserver)

        // System wake from sleep
        let wakeObserver = NotificationCenter.default.addObserver(
            forName: .systemDidWake,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSystemWake()
            }
        }
        systemEventObservers.append(wakeObserver)

        // Screen locked
        let lockObserver = NotificationCenter.default.addObserver(
            forName: .screenDidLock,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenLock()
            }
        }
        systemEventObservers.append(lockObserver)

        // Screen unlocked
        let unlockObserver = NotificationCenter.default.addObserver(
            forName: .screenDidUnlock,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenUnlock()
            }
        }
        systemEventObservers.append(unlockObserver)
    }

    /// Handle system wake from sleep
    private func handleSystemWake() {
        log("ProactiveAssistantsPlugin: System woke from sleep")

        // Reset failure counter
        consecutiveFailures = 0
        lastCaptureSucceeded = true

        // If we were monitoring before sleep, reinitialize capture service
        if wasMonitoringBeforeSleep && isMonitoring {
            log("ProactiveAssistantsPlugin: Restarting screen capture after wake")

            // Reinitialize the screen capture service
            screenCaptureService = ScreenCaptureService()

            // Refresh permission state
            refreshScreenRecordingPermission()
        }

        wasMonitoringBeforeSleep = false
    }

    /// Handle screen lock - pause capture
    private func handleScreenLock() {
        log("ProactiveAssistantsPlugin: Screen locked - pausing capture")

        wasMonitoringBeforeLock = isMonitoring

        // Pause the capture timer while locked
        captureTimer?.invalidate()
        captureTimer = nil
    }

    /// Handle screen unlock - resume capture
    private func handleScreenUnlock() {
        log("ProactiveAssistantsPlugin: Screen unlocked - resuming capture")

        // Reset failure counter
        consecutiveFailures = 0
        lastCaptureSucceeded = true

        if wasMonitoringBeforeLock && isMonitoring {
            log("ProactiveAssistantsPlugin: Restarting capture timer after unlock")

            // Reinitialize screen capture service to ensure fresh state
            screenCaptureService = ScreenCaptureService()

            // Restart capture timer
            captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.captureFrame()
                }
            }
        } else if wasMonitoringBeforeLock && !isMonitoring {
            // We stopped monitoring while locked, restart it
            log("ProactiveAssistantsPlugin: Restarting monitoring after unlock")
            startMonitoring { success, error in
                if !success, let error = error {
                    log("Failed to restart monitoring after unlock: \(error)")
                }
            }
        }

        wasMonitoringBeforeLock = false
    }

    /// Handle repeated capture failures (likely permission issue)
    private func handleRepeatedCaptureFailures() {
        log("ProactiveAssistantsPlugin: Detected \(consecutiveFailures) consecutive capture failures")

        // Refresh permission state
        refreshScreenRecordingPermission()

        // Check if permission is actually lost
        if !hasScreenRecordingPermission {
            log("ProactiveAssistantsPlugin: Screen recording permission lost")

            // Post notification for AppState to update UI
            NotificationCenter.default.post(name: .screenCapturePermissionLost, object: nil)

            // Stop monitoring since we can't capture
            stopMonitoring()

            // Send user notification
            NotificationService.shared.sendNotification(
                title: "Screen Recording Permission Required",
                message: "Omi needs screen recording permission to continue monitoring. Please re-enable it in System Settings."
            )
        } else {
            // Permission is still granted but capture is failing
            // Try reinitializing the capture service
            log("ProactiveAssistantsPlugin: Permission still granted, reinitializing capture service")
            screenCaptureService = ScreenCaptureService()
            consecutiveFailures = 0
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let assistantEvent = Notification.Name("assistantEvent")
}

// MARK: - Backward Compatibility Alias

typealias FocusPlugin = ProactiveAssistantsPlugin
typealias MonitoringService = ProactiveAssistantsPlugin
