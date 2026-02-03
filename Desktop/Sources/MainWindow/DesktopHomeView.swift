import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()
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
                    .task {
                        // Trigger eager data loading when main content appears
                        await viewModelContainer.loadAllData()
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
            // Sidebar (with click-through so first click activates items even when window is inactive)
            SidebarView(
                selectedIndex: $selectedIndex,
                isCollapsed: $isSidebarCollapsed,
                appState: appState
            )
            .clickThrough()

            // Main content area with rounded container
            ZStack {
                // Content container background
                RoundedRectangle(cornerRadius: 16)
                    .fill(OmiColors.backgroundSecondary.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(OmiColors.backgroundTertiary.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 20, x: 0, y: 4)

                // Page content - ZStack keeps all views alive
                ZStack {
                    DashboardPage(viewModel: viewModelContainer.dashboardViewModel, isActive: selectedIndex == 0)
                        .opacity(selectedIndex == 0 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 0)
                        .trackRender("DashboardPage")

                    ConversationsPage(appState: appState)
                        .opacity(selectedIndex == 1 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 1)
                        .trackRender("ConversationsPage")

                    ChatPage(appProvider: viewModelContainer.appProvider, chatProvider: viewModelContainer.chatProvider)
                        .opacity(selectedIndex == 2 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 2)
                        .trackRender("ChatPage")

                    MemoriesPage(viewModel: viewModelContainer.memoriesViewModel)
                        .opacity(selectedIndex == 3 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 3)
                        .trackRender("MemoriesPage")

                    TasksPage(viewModel: viewModelContainer.tasksViewModel)
                        .opacity(selectedIndex == 4 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 4)
                        .trackRender("TasksPage")

                    FocusPage()
                        .opacity(selectedIndex == 5 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 5)
                        .trackRender("FocusPage")

                    AdvicePage()
                        .opacity(selectedIndex == 6 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 6)
                        .trackRender("AdvicePage")

                    RewindPage()
                        .opacity(selectedIndex == 7 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 7)
                        .trackRender("RewindPage")

                    AppsPage(appProvider: viewModelContainer.appProvider)
                        .opacity(selectedIndex == 8 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 8)
                        .trackRender("AppsPage")

                    SettingsPage(appState: appState)
                        .opacity(selectedIndex == 9 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 9)
                        .trackRender("SettingsPage")

                    PermissionsPage(appState: appState)
                        .opacity(selectedIndex == 10 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 10)
                        .trackRender("PermissionsPage")

                    DeviceSettingsPage()
                        .opacity(selectedIndex == 11 ? 1 : 0)
                        .allowsHitTesting(selectedIndex == 11)
                        .trackRender("DeviceSettingsPage")
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToRewindSettings)) { _ in
            // Set pending section before navigating
            SettingsContentView.pendingSection = .rewind
            // Navigate to Settings page (index 8)
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = SidebarNavItem.settings.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToRewind)) { _ in
            // Navigate to Rewind page (index 6) - triggered by global hotkey Cmd+Option+R
            log("DesktopHomeView: Received navigateToRewind notification, navigating to Rewind (index \(SidebarNavItem.rewind.rawValue))")
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = SidebarNavItem.rewind.rawValue
            }
        }
    }
}

#Preview {
    DesktopHomeView()
}
