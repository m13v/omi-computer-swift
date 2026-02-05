import SwiftUI
import FirebaseCore
import FirebaseAuth
import Mixpanel
import Sentry
import Sparkle

// MARK: - Launch Mode
/// Determines which UI to show based on command-line arguments
enum LaunchMode: String {
    case full = "full"       // Normal app with full sidebar
    case rewind = "rewind"   // Rewind-only mode (no sidebar)

    static func fromCommandLine() -> LaunchMode {
        // Check for --mode=rewind argument
        for arg in CommandLine.arguments {
            if arg == "--mode=rewind" {
                NSLog("OMI LaunchMode: Detected rewind mode from command line")
                return .rewind
            }
        }
        return .full
    }
}

// Simple observable state without Firebase types
@MainActor
class AuthState: ObservableObject {
    static let shared = AuthState()

    // UserDefaults keys (must match AuthService)
    private static let kAuthIsSignedIn = "auth_isSignedIn"
    private static let kAuthUserEmail = "auth_userEmail"
    private static let kAuthUserId = "auth_userId"

    @Published var isSignedIn: Bool
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var userEmail: String?

    private init() {
        // Restore auth state from UserDefaults immediately on init (before UI renders)
        let savedSignedIn = UserDefaults.standard.bool(forKey: Self.kAuthIsSignedIn)
        let savedEmail = UserDefaults.standard.string(forKey: Self.kAuthUserEmail)
        self.isSignedIn = savedSignedIn
        self.userEmail = savedEmail
        NSLog("OMI AuthState: Initialized with savedSignedIn=%@, email=%@",
              savedSignedIn ? "true" : "false", savedEmail ?? "nil")
    }

    func update(isSignedIn: Bool, userEmail: String? = nil) {
        self.isSignedIn = isSignedIn
        self.userEmail = userEmail
    }

    /// Get the user's Firebase UID from UserDefaults (fallback when Firebase SDK auth fails)
    var userId: String? {
        UserDefaults.standard.string(forKey: Self.kAuthUserId)
    }
}

@main
struct OMIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var authState = AuthState.shared
    @Environment(\.openWindow) private var openWindow

    /// Launch mode determined at startup from command-line arguments
    static let launchMode = LaunchMode.fromCommandLine()

    /// Window title with version number (different for rewind mode)
    private var windowTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let baseName = Self.launchMode == .rewind ? "Omi Rewind" : "Omi"
        return version.isEmpty ? baseName : "\(baseName) v\(version)"
    }

    /// Window size based on launch mode
    private var defaultWindowSize: CGSize {
        Self.launchMode == .rewind ? CGSize(width: 1000, height: 700) : CGSize(width: 1200, height: 800)
    }

    var body: some Scene {
        // Main desktop window - same view for both modes, sidebar hidden in rewind mode
        Window(windowTitle, id: "main") {
            DesktopHomeView()
                .onAppear {
                    log("OmiApp: Main window content appeared (mode: \(Self.launchMode.rawValue))")
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)

        // Note: Menu bar is now handled by NSStatusBar in AppDelegate.setupMenuBar()
        // for better reliability on macOS Sequoia (SwiftUI MenuBarExtra had rendering issues)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var sentryHeartbeatTimer: Timer?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var statusBarItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: applicationDidFinishLaunching started (mode: \(OMIApp.launchMode.rawValue))")
        log("AppDelegate: AuthState.isSignedIn=\(AuthState.shared.isSignedIn)")

        // Initialize NotificationService early to set up UNUserNotificationCenterDelegate
        // This ensures notifications display properly when app is in foreground
        _ = NotificationService.shared

        // Initialize Sentry for crash reporting and error tracking (including dev builds)
        let isDev = AnalyticsManager.isDevBuild
        SentrySDK.start { options in
            options.dsn = "https://8f700584deda57b26041ff015539c8c1@o4507617161314304.ingest.us.sentry.io/4510790686277632"
            options.debug = false
            options.enableAutoSessionTracking = true
            options.environment = isDev ? "development" : "production"
        }
        log("Sentry initialized (environment: \(isDev ? "development" : "production"))")

        // Initialize Firebase
        let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")

        if let path = plistPath,
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
            AuthService.shared.configure()
        }

        // Initialize analytics (MixPanel + PostHog)
        AnalyticsManager.shared.initialize()
        AnalyticsManager.shared.appLaunched()
        AnalyticsManager.shared.trackDisplayInfo()
        AnalyticsManager.shared.trackFirstLaunchIfNeeded()

        // Start resource monitoring (memory, CPU, disk)
        ResourceMonitor.shared.start()

        // Recover any pending/failed transcription sessions from previous runs
        Task {
            await TranscriptionRetryService.shared.recoverPendingTranscriptions()
            TranscriptionRetryService.shared.start()
        }

        // Identify user if already signed in
        if AuthState.shared.isSignedIn {
            AnalyticsManager.shared.identify()
            // Set Sentry user context (now enabled for dev builds too)
            if let email = AuthState.shared.userEmail {
                let sentryUser = Sentry.User()
                sentryUser.email = email
                sentryUser.username = AuthService.shared.displayName.isEmpty ? nil : AuthService.shared.displayName
                SentrySDK.setUser(sentryUser)
            }
            // Fetch conversations on startup
            AuthService.shared.fetchConversations()
        }

        // Register for Apple Events to handle URL scheme
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Register global hotkey for Rewind (Cmd+Shift+Space)
        setupGlobalHotkeys()

        // Set up dock icon visibility based on window state
        setupDockIconObservers()

        // Set up menu bar icon with NSStatusBar (more reliable than SwiftUI MenuBarExtra)
        Task { @MainActor in
            self.setupMenuBar()
        }

        // Start Sentry heartbeat timer (every 5 minutes) to capture breadcrumbs periodically
        startSentryHeartbeat()

        // Activate app and show main window after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            log("AppDelegate: Checking windows after 0.2s delay, count=\(NSApp.windows.count)")
            NSApp.activate(ignoringOtherApps: true)
            var foundOmiWindow = false
            for window in NSApp.windows {
                log("AppDelegate: Window title='\(window.title)', isVisible=\(window.isVisible)")
                if window.title.hasPrefix("Omi") {
                    foundOmiWindow = true
                    window.makeKeyAndOrderFront(nil)
                    window.appearance = NSAppearance(named: .darkAqua)
                    // Show dock icon when main window is visible
                    NSApp.setActivationPolicy(.regular)
                    log("AppDelegate: Dock icon shown on launch")
                }
            }
            if !foundOmiWindow {
                log("AppDelegate: WARNING - 'Omi' window not found!")
            }
        }

        log("AppDelegate: applicationDidFinishLaunching completed")
    }

    /// Start a timer that sends Sentry session snapshots every 5 minutes
    /// This ensures we have breadcrumbs captured even without errors
    private func startSentryHeartbeat() {
        // Now runs in dev builds too since Sentry is always initialized
        sentryHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            // Capture a session heartbeat event with current breadcrumbs
            SentrySDK.capture(message: "Session Heartbeat") { scope in
                scope.setLevel(.info)
                scope.setTag(value: "heartbeat", key: "event_type")
            }
            log("Sentry: Session heartbeat captured")
        }
    }

    /// Set up global keyboard shortcuts
    private func setupGlobalHotkeys() {
        // Handler for Ctrl+Option+R -> Open Rewind
        let hotkeyHandler: (NSEvent) -> NSEvent? = { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let keyCode = event.keyCode

            // Log modifier key presses for debugging
            if modifiers.contains(.control) || modifiers.contains(.option) {
                log("AppDelegate: [HOTKEY] keyCode=\(keyCode), modifiers=\(modifiers.rawValue) (ctrl=\(modifiers.contains(.control)), opt=\(modifiers.contains(.option)))")
            }

            // Check for Ctrl+Option+R (less likely to conflict with system shortcuts)
            let isCtrlOption = modifiers.contains(.control) && modifiers.contains(.option)
            let isR = keyCode == 15 // R key

            if isCtrlOption && isR {
                log("AppDelegate: [HOTKEY] Rewind hotkey MATCHED (Ctrl+Option+R)")
                DispatchQueue.main.async {
                    log("AppDelegate: [HOTKEY] Activating app and posting notification")
                    // Bring app to front
                    NSApp.activate(ignoringOtherApps: true)
                    // Find and show main window
                    for window in NSApp.windows {
                        if window.title.hasPrefix("Omi") {
                            window.makeKeyAndOrderFront(nil)
                            break
                        }
                    }
                    // Post notification to navigate to Rewind
                    NotificationCenter.default.post(name: .navigateToRewind, object: nil)
                    log("AppDelegate: [HOTKEY] Posted navigateToRewind notification")
                }
            }
            return event
        }

        // Global monitor - for when OTHER apps are focused (requires Accessibility permission)
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = hotkeyHandler(event)
        }

        // Local monitor - for when THIS app is focused
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            return hotkeyHandler(event)
        }

        log("AppDelegate: Hotkey monitors registered - global=\(globalHotkeyMonitor != nil), local=\(localHotkeyMonitor != nil)")
        log("AppDelegate: Hotkey is Ctrl+Option+R (⌃⌥R)")
    }

    /// Set up observers to show/hide dock icon when main window appears/disappears
    private func setupDockIconObservers() {
        // Show dock icon when a window becomes visible
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title.hasPrefix("Omi") else { return }
            self?.showDockIcon()
        }
        windowObservers.append(showObserver)

        // Hide dock icon when window closes (check if any Omi windows remain)
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title.hasPrefix("Omi") else { return }
            // Delay check to allow window to fully close
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self?.checkAndHideDockIconIfNeeded()
            }
        }
        windowObservers.append(closeObserver)

        // Also hide dock icon when window is minimized
        let minimizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title.hasPrefix("Omi") else { return }
            self?.checkAndHideDockIconIfNeeded()
        }
        windowObservers.append(minimizeObserver)

        // Show dock icon when window is restored from minimize
        let deminiaturizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.title.hasPrefix("Omi") else { return }
            self?.showDockIcon()
        }
        windowObservers.append(deminiaturizeObserver)

        log("AppDelegate: Dock icon observers set up")
    }

    /// Show the app icon in the Dock
    private func showDockIcon() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            log("AppDelegate: Dock icon shown")
        }
    }

    /// Hide the app icon from the Dock (if no Omi windows are visible)
    private func checkAndHideDockIconIfNeeded() {
        // Check if any Omi windows are still visible (not minimized, not closed)
        let hasVisibleOmiWindow = NSApp.windows.contains { window in
            window.title.hasPrefix("Omi") && window.isVisible && !window.isMiniaturized
        }

        if !hasVisibleOmiWindow && NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            log("AppDelegate: Dock icon hidden (no visible Omi windows)")
        }
    }

    /// Set up menu bar icon using NSStatusBar (more reliable than SwiftUI MenuBarExtra)
    @MainActor private func setupMenuBar() {
        log("AppDelegate: [MENUBAR] Setting up NSStatusBar menu (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusBarItem = statusBarItem else {
            log("AppDelegate: [MENUBAR] ERROR - Failed to create status bar item")
            SentrySDK.capture(message: "Failed to create NSStatusItem") { scope in
                scope.setLevel(.error)
                scope.setTag(value: "menu_bar", key: "component")
            }
            return
        }

        log("AppDelegate: [MENUBAR] NSStatusItem created successfully")

        // Set up the button with icon
        if let button = statusBarItem.button {
            let iconName = OMIApp.launchMode == .rewind ? "clock.arrow.circlepath" : "waveform.circle.fill"
            if let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                icon.isTemplate = true
                button.image = icon
                log("AppDelegate: [MENUBAR] Icon '\(iconName)' set successfully")
            } else {
                log("AppDelegate: [MENUBAR] WARNING - Failed to load SF Symbol '\(iconName)'")
            }
            button.toolTip = OMIApp.launchMode == .rewind ? "Omi Rewind" : "Omi Computer"
        } else {
            log("AppDelegate: [MENUBAR] WARNING - statusBarItem.button is nil")
        }

        // Create menu
        let menu = NSMenu()

        // Open Omi item
        let openItem = NSMenuItem(title: "Open Omi", action: #selector(openOmiFromMenu), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Check for Updates
        let updatesItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        // Sign out / User info
        if AuthState.shared.isSignedIn {
            if let email = AuthState.shared.userEmail {
                let emailItem = NSMenuItem(title: "Signed in as \(email)", action: nil, keyEquivalent: "")
                emailItem.isEnabled = false
                menu.addItem(emailItem)
                menu.addItem(NSMenuItem.separator())
            }

            let resetItem = NSMenuItem(title: "Reset Onboarding...", action: #selector(resetOnboarding), keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)

            menu.addItem(NSMenuItem.separator())

            let reportItem = NSMenuItem(title: "Report Issue...", action: #selector(reportIssue), keyEquivalent: "")
            reportItem.target = self
            menu.addItem(reportItem)

            menu.addItem(NSMenuItem.separator())

            let signOutItem = NSMenuItem(title: "Sign Out", action: #selector(signOut), keyEquivalent: "")
            signOutItem.target = self
            menu.addItem(signOutItem)
        } else {
            let notSignedInItem = NSMenuItem(title: "Not signed in", action: nil, keyEquivalent: "")
            notSignedInItem.isEnabled = false
            menu.addItem(notSignedInItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit item
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusBarItem.menu = menu
        menu.delegate = self
        log("AppDelegate: [MENUBAR] Menu bar setup completed - icon visible in status bar")
    }

    @MainActor @objc private func openOmiFromMenu() {
        AnalyticsManager.shared.menuBarActionClicked(action: "open_omi")
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.title.hasPrefix("Omi") {
                window.makeKeyAndOrderFront(nil)
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    @MainActor @objc private func checkForUpdates() {
        AnalyticsManager.shared.menuBarActionClicked(action: "check_updates")
        UpdaterViewModel.shared.checkForUpdates()
    }

    @MainActor @objc private func resetOnboarding() {
        AnalyticsManager.shared.menuBarActionClicked(action: "reset_onboarding")
        AppState().resetOnboardingAndRestart()
    }

    @MainActor @objc private func reportIssue() {
        AnalyticsManager.shared.menuBarActionClicked(action: "report_issue")
        FeedbackWindow.show(userEmail: AuthState.shared.userEmail)
    }

    @MainActor @objc private func signOut() {
        AnalyticsManager.shared.menuBarActionClicked(action: "sign_out")
        ProactiveAssistantsPlugin.shared.stopMonitoring()
        try? AuthService.shared.signOut()
    }

    @MainActor @objc private func quitApp() {
        AnalyticsManager.shared.menuBarActionClicked(action: "quit")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - NSMenuDelegate
    func menuWillOpen(_ menu: NSMenu) {
        log("AppDelegate: [MENUBAR] Menu opened by user")
        AnalyticsManager.shared.menuBarOpened()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove window observers
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        // Remove hotkey monitors
        if let monitor = globalHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalHotkeyMonitor = nil
        }
        if let monitor = localHotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            localHotkeyMonitor = nil
        }

        // Stop heartbeat timer
        sentryHeartbeatTimer?.invalidate()
        sentryHeartbeatTimer = nil

        // Stop transcription retry service
        TranscriptionRetryService.shared.stop()

        // Report final resources before termination
        ResourceMonitor.shared.reportResourcesNow(context: "app_terminating")
        ResourceMonitor.shared.stop()

        // Capture final session snapshot before termination (now enabled for dev builds too)
        SentrySDK.capture(message: "App Terminating") { scope in
            scope.setLevel(.info)
            scope.setTag(value: "lifecycle", key: "event_type")
        }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        NSLog("OMI AppDelegate: Received URL event: %@", urlString)

        Task { @MainActor in
            AuthService.shared.handleOAuthCallback(url: url)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AnalyticsManager.shared.appBecameActive()
    }

    func applicationWillResignActive(_ notification: Notification) {
        AnalyticsManager.shared.appResignedActive()
    }
}
