import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @ObservedObject private var authState = AuthState.shared
    @State private var selectedIndex: Int = 0
    @State private var isSidebarCollapsed: Bool = false

    var body: some View {
        Group {
            if !authState.isSignedIn {
                // State 1: Not signed in - show sign in
                SignInView(authState: authState)
                    .onAppear {
                        log("DesktopHomeView: Showing SignInView (not signed in)")
                    }
            } else if !appState.hasCompletedOnboarding {
                // State 2: Signed in but onboarding not complete
                OnboardingView(appState: appState, onComplete: nil)
                    .onAppear {
                        log("DesktopHomeView: Showing OnboardingView (signed in, not onboarded)")
                    }
            } else {
                // State 3: Signed in and onboarded - show main content
                mainContent
                    .onAppear {
                        log("DesktopHomeView: Showing mainContent (signed in and onboarded)")
                        // Check all permissions on launch
                        appState.checkAllPermissions()

                        let settings = AssistantSettings.shared

                        // Auto-start transcription if enabled in settings
                        if settings.transcriptionEnabled && !appState.isTranscribing {
                            log("DesktopHomeView: Auto-starting transcription")
                            appState.startTranscription()
                        } else if !settings.transcriptionEnabled {
                            log("DesktopHomeView: Transcription disabled in settings, skipping auto-start")
                        }

                        // Start proactive assistants monitoring if enabled in settings
                        if settings.screenAnalysisEnabled {
                            ProactiveAssistantsPlugin.shared.startMonitoring { success, error in
                                if success {
                                    log("DesktopHomeView: Screen analysis started")
                                } else {
                                    log("DesktopHomeView: Screen analysis failed to start: \(error ?? "unknown")")
                                }
                            }
                        } else {
                            log("DesktopHomeView: Screen analysis disabled in settings, skipping auto-start")
                        }
                    }
            }
        }
        .background(OmiColors.backgroundPrimary)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(OmiColors.purplePrimary)
        .onAppear {
            log("DesktopHomeView: View appeared - isSignedIn=\(authState.isSignedIn), hasCompletedOnboarding=\(appState.hasCompletedOnboarding)")
            // Force dark appearance on the window
            DispatchQueue.main.async {
                for window in NSApp.windows {
                    if window.title == "Omi" {
                        window.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
        }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            // Sidebar
            SidebarView(
                selectedIndex: $selectedIndex,
                isCollapsed: $isSidebarCollapsed,
                appState: appState
            )

            // Main content area with rounded container
            ZStack {
                // Content container
                RoundedRectangle(cornerRadius: 16)
                    .fill(OmiColors.backgroundSecondary.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(OmiColors.backgroundTertiary.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 4)

                // Page content
                Group {
                    switch selectedIndex {
                    case 0:
                        ConversationsPage(appState: appState)
                    case 1:
                        ChatPage()
                    case 2:
                        MemoriesPage()
                    case 3:
                        TasksPage()
                    case 4:
                        FocusPage()
                    case 5:
                        AdvicePage()
                    case 6:
                        RewindPage()
                    case 7:
                        AppsPage()
                    case 8:
                        SettingsPage(appState: appState)
                    case 9:
                        PermissionsPage(appState: appState)
                    default:
                        ConversationsPage(appState: appState)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
    }
}

#Preview {
    DesktopHomeView()
}
