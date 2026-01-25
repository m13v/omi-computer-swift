import SwiftUI
import FirebaseCore
import FirebaseAuth

// Simple observable state without Firebase types
class AuthState: ObservableObject {
    static let shared = AuthState()

    @Published var isSignedIn: Bool = false
    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var userEmail: String?

    private init() {}

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
            Text("OMI")
        }
        .menuBarExtraStyle(.menu)

        Window("Welcome to OMI-COMPUTER", id: "onboarding") {
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
                        if window.title == "Welcome to OMI-COMPUTER" || window.contentView?.subviews.first != nil {
                            window.center()
                            window.makeKeyAndOrderFront(nil)
                            window.orderFrontRegardless()
                        }
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // Handle OAuth callback URLs
            .onOpenURL { url in
                NSLog("OMI: Received URL: %@", url.absoluteString)
                Task { @MainActor in
                    AuthService.shared.handleOAuthCallback(url: url)
                }
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize Firebase
        let plistPath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")

        if let path = plistPath,
           let options = FirebaseOptions(contentsOfFile: path) {
            FirebaseApp.configure(options: options)
            AuthService.shared.configure()
        }

        // Register for Apple Events to handle URL scheme
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
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

            Button(appState.isMonitoring ? "Stop Monitoring" : "Start Monitoring") {
                appState.toggleMonitoring()
            }
            .keyboardShortcut("m", modifiers: .command)

            Button("Grant Screen Permission") {
                appState.openScreenRecordingPreferences()
            }

            Button("Show Onboarding") {
                openOnboarding()
            }

            Divider()

            Button("Sign Out") {
                // Stop monitoring if running
                if appState.isMonitoring {
                    appState.stopMonitoring()
                }
                // Sign out
                try? AuthService.shared.signOut()
                // Open sign-in window and bring to front
                openOnboarding()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows {
                        if window.title == "Welcome to OMI-COMPUTER" {
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
                        if window.title == "Welcome to OMI-COMPUTER" {
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
