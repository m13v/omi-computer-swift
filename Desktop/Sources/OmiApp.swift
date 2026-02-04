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
        // Main desktop window - shows different content based on launch mode
        Window(windowTitle, id: "main") {
            Group {
                if Self.launchMode == .rewind {
                    RewindOnlyView()
                } else {
                    DesktopHomeView()
                }
            }
            .onAppear {
                log("OmiApp: Main window content appeared (mode: \(Self.launchMode.rawValue))")
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)

        // Menu bar - simplified in rewind mode
        MenuBarExtra {
            if Self.launchMode == .rewind {
                RewindMenuBarView(openMain: { openWindow(id: "main") })
            } else {
                MenuBarView(appState: appState, authState: authState, openMain: { openWindow(id: "main") })
            }
        } label: {
            Text(Self.launchMode == .rewind ? "Rewind" : "Omi")
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Rewind Mode Menu Bar
/// Simplified menu bar for rewind-only mode
struct RewindMenuBarView: View {
    var openMain: () -> Void = {}

    var body: some View {
        Button("Open Rewind") {
            AnalyticsManager.shared.menuBarActionClicked(action: "open_rewind")
            openMain()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.title.contains("Rewind") || window.title.hasPrefix("Omi") {
                        window.makeKeyAndOrderFront(nil)
                        window.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Quit") {
            AnalyticsManager.shared.menuBarActionClicked(action: "quit")
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // Track when menu bar is opened (this view appears)
        Color.clear.frame(height: 0)
            .onAppear {
                AnalyticsManager.shared.menuBarOpened()
            }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var sentryHeartbeatTimer: Timer?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isRewindMode = OMIApp.launchMode == .rewind
        log("AppDelegate: applicationDidFinishLaunching started (mode: \(OMIApp.launchMode.rawValue))")
        log("AppDelegate: AuthState.isSignedIn=\(AuthState.shared.isSignedIn)")

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

    func applicationWillTerminate(_ notification: Notification) {
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

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authState: AuthState
    @ObservedObject var updaterViewModel = UpdaterViewModel.shared
    var openMain: () -> Void = {}

    var body: some View {
        Button("Open Omi") {
            AnalyticsManager.shared.menuBarActionClicked(action: "open_omi")
            openMain()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.title.hasPrefix("Omi") {
                        window.makeKeyAndOrderFront(nil)
                        window.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        Button("Check for Updates...") {
            AnalyticsManager.shared.menuBarActionClicked(action: "check_updates")
            updaterViewModel.checkForUpdates()
        }
        .disabled(!updaterViewModel.canCheckForUpdates)

        Divider()

        if authState.isSignedIn {
            if let email = authState.userEmail {
                Text("Signed in as \(email)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Reset Onboarding...") {
                AnalyticsManager.shared.menuBarActionClicked(action: "reset_onboarding")
                appState.resetOnboardingAndRestart()
            }

            Divider()

            Button("Report Issue...") {
                AnalyticsManager.shared.menuBarActionClicked(action: "report_issue")
                FeedbackWindow.show(userEmail: authState.userEmail)
            }

            Divider()

            Button("Sign Out") {
                AnalyticsManager.shared.menuBarActionClicked(action: "sign_out")
                // Stop monitoring if running
                ProactiveAssistantsPlugin.shared.stopMonitoring()
                // Sign out
                try? AuthService.shared.signOut()
            }
        } else {
            Text("Not signed in")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Divider()

        Button("Quit") {
            AnalyticsManager.shared.menuBarActionClicked(action: "quit")
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)

        // Track when menu bar is opened (this view appears)
        Color.clear.frame(height: 0)
            .onAppear {
                AnalyticsManager.shared.menuBarOpened()
            }
    }
}
