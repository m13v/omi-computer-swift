import SwiftUI
import UserNotifications

@main
struct OMIApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, openOnboarding: { openWindow(id: "onboarding") })
        } label: {
            Text("OMI")
        }
        .menuBarExtraStyle(.menu)

        Window("Welcome to OMI", id: "onboarding") {
            OnboardingView(appState: appState)
                .onAppear {
                    // Center and activate the window after a brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        for window in NSApp.windows {
                            if window.title == "Welcome to OMI" || window.contentView?.subviews.first != nil {
                                window.center()
                                window.makeKeyAndOrderFront(nil)
                                window.orderFrontRegardless()
                            }
                        }
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up notification center delegate
        UNUserNotificationCenter.current().delegate = self
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    var openOnboarding: () -> Void = {}

    var body: some View {
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

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
