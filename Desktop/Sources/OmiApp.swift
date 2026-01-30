import SwiftUI
import FirebaseCore
import FirebaseAuth
import Mixpanel
import Sentry
import Sparkle

// Simple observable state without Firebase types
@MainActor
class AuthState: ObservableObject {
    static let shared = AuthState()

    // UserDefaults keys (must match AuthService)
    private static let kAuthIsSignedIn = "auth_isSignedIn"
    private static let kAuthUserEmail = "auth_userEmail"

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
}

@main
struct OMIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var authState = AuthState.shared
    @Environment(\.openWindow) private var openWindow

    /// Window title with version number
    private var windowTitle: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? "Omi" : "Omi v\(version)"
    }

    var body: some Scene {
        // Main desktop window - handles sign in, onboarding, and main content
        Window(windowTitle, id: "main") {
            DesktopHomeView()
                .onAppear {
                    log("OmiApp: Main window content appeared")
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.presented)

        // Menu bar
        MenuBarExtra {
            MenuBarView(appState: appState, authState: authState, openMain: { openWindow(id: "main") })
        } label: {
            Text("Omi")
        }
        .menuBarExtraStyle(.menu)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var sentryHeartbeatTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate: applicationDidFinishLaunching started")
        log("AppDelegate: AuthState.isSignedIn=\(AuthState.shared.isSignedIn)")

        // Initialize Sentry for crash reporting and error tracking
        SentrySDK.start { options in
            options.dsn = "https://8f700584deda57b26041ff015539c8c1@o4507617161314304.ingest.us.sentry.io/4510790686277632"
            options.debug = false
            options.enableAutoSessionTracking = true
            // Set environment based on build configuration
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }
        log("Sentry initialized")

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

        // Identify user if already signed in
        if AuthState.shared.isSignedIn {
            AnalyticsManager.shared.identify()
            // Set Sentry user context
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
        sentryHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            // Capture a session heartbeat event with current breadcrumbs
            SentrySDK.capture(message: "Session Heartbeat") { scope in
                scope.setLevel(.info)
                scope.setTag(value: "heartbeat", key: "event_type")
            }
            log("Sentry: Session heartbeat captured")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop heartbeat timer
        sentryHeartbeatTimer?.invalidate()
        sentryHeartbeatTimer = nil

        // Capture final session snapshot before termination
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
}

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authState: AuthState
    @ObservedObject var updaterViewModel = UpdaterViewModel.shared
    var openMain: () -> Void = {}

    var body: some View {
        Button("Open Omi") {
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

            Button("Proactive Assistant Settings") {
                SettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Grant Screen Permission") {
                ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
            }

            Divider()

            Button("Report Issue...") {
                FeedbackWindow.show(userEmail: authState.userEmail)
            }

            Divider()

            Button("Sign Out") {
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
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
