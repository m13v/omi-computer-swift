import SwiftUI
import FirebaseCore
import FirebaseAuth
import Mixpanel
import Sentry

// Simple observable state without Firebase types
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

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, authState: authState, openOnboarding: { openWindow(id: "onboarding") })
        } label: {
            Text("Omi")
        }
        .menuBarExtraStyle(.menu)

        Window("Welcome to Omi Computer", id: "onboarding") {
            Group {
                if authState.isSignedIn {
                    OnboardingView(appState: appState)
                } else {
                    SignInView(authState: authState)
                }
            }
            .onAppear {
                // Center and activate the window after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    for window in NSApp.windows {
                        if window.title == "Welcome to Omi Computer" || window.contentView?.subviews.first != nil {
                            window.center()
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // Note: OAuth callback URLs are handled by AppDelegate.handleGetURLEvent
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var sentryHeartbeatTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Initialize MixPanel analytics
        MixpanelManager.shared.initialize()
        MixpanelManager.shared.appLaunched()

        // Identify user if already signed in
        if AuthState.shared.isSignedIn {
            MixpanelManager.shared.identify()
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
    var openOnboarding: () -> Void = {}

    var body: some View {
        if authState.isSignedIn {
            if let email = authState.userEmail {
                Text("Signed in as \(email)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button(appState.isTranscribing ? "Stop Transcription" : "Start Transcription") {
                appState.toggleTranscription()
            }
            .keyboardShortcut("t", modifiers: .command)

            if appState.isTranscribing {
                Text("🎙️ Recording...")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            Button("Proactive Assistant Settings") {
                SettingsWindow.show()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Grant Screen Permission") {
                ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
            }

            Button("Show Onboarding") {
                openOnboarding()
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
                // Open sign-in window and bring to front
                openOnboarding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        if window.title == "Welcome to Omi Computer" {
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                }
            }
        } else {
            Button("Sign In") {
                openOnboarding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        if window.title == "Welcome to Omi Computer" {
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                }
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
