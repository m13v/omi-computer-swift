import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @StateObject private var viewModelContainer = ViewModelContainer()
    @ObservedObject private var authState = AuthState.shared
    @State private var selectedIndex: Int = {
        if OMIApp.launchMode == .rewind { return SidebarNavItem.rewind.rawValue }
        if UserDefaults.standard.bool(forKey: "tierGatingEnabled") { return SidebarNavItem.conversations.rawValue }
        return 0
    }()
    @State private var isSidebarCollapsed: Bool = false

    // Settings sidebar state
    @State private var selectedSettingsSection: SettingsContentView.SettingsSection = .general
    @State private var previousIndexBeforeSettings: Int = 0

    /// Whether we're currently viewing the settings page
    private var isInSettings: Bool {
        selectedIndex == SidebarNavItem.settings.rawValue
    }

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
                        // Load conversations/folders in parallel with other data
                        async let vmLoad: Void = viewModelContainer.loadAllData()
                        async let conversations: Void = appState.loadConversations()
                        async let folders: Void = appState.loadFolders()
                        _ = await (vmLoad, conversations, folders)
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

    /// Whether to hide the sidebar (rewind mode)
    private var hideSidebar: Bool {
        OMIApp.launchMode == .rewind
    }

    /// Update store auto-refresh based on which page is visible
    private func updateStoreActivity(for index: Int) {
        viewModelContainer.tasksStore.isActive =
            index == SidebarNavItem.dashboard.rawValue || index == SidebarNavItem.tasks.rawValue
        viewModelContainer.memoriesViewModel.isActive =
            index == SidebarNavItem.memories.rawValue
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            // Show settings sidebar when in settings (always visible, even in rewind mode)
            if isInSettings {
                SettingsSidebar(
                    selectedSection: $selectedSettingsSection,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedIndex = previousIndexBeforeSettings
                        }
                    }
                )
            } else if !hideSidebar {
                // Main sidebar only in full mode (hidden in rewind mode)
                SidebarView(
                    selectedIndex: $selectedIndex,
                    isCollapsed: $isSidebarCollapsed,
                    appState: appState
                )
                .clickThrough()
            }

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

                // Page content - switch recreates views on tab change
                Group {
                    switch selectedIndex {
                    case 0:
                        DashboardPage(viewModel: viewModelContainer.dashboardViewModel)
                    case 1:
                        ConversationsPage(appState: appState)
                    case 2:
                        ChatPage(appProvider: viewModelContainer.appProvider, chatProvider: viewModelContainer.chatProvider)
                    case 3:
                        MemoriesPage(viewModel: viewModelContainer.memoriesViewModel)
                    case 4:
                        TasksPage(viewModel: viewModelContainer.tasksViewModel)
                    case 5:
                        FocusPage()
                    case 6:
                        AdvicePage()
                    case 7:
                        RewindPage()
                    case 8:
                        AppsPage(appProvider: viewModelContainer.appProvider)
                    case 9:
                        SettingsPage(appState: appState, selectedSection: $selectedSettingsSection)
                    case 10:
                        PermissionsPage(appState: appState)
                    case 11:
                        DeviceSettingsPage()
                    case 12:
                        HelpPage()
                    default:
                        DashboardPage(viewModel: viewModelContainer.dashboardViewModel)
                    }
                }
                .id(selectedIndex)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .animation(.easeInOut(duration: 0.2), value: selectedIndex)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToRewindSettings)) { _ in
            // Set the section directly and navigate to settings
            selectedSettingsSection = .rewind
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = SidebarNavItem.settings.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToDeviceSettings)) { _ in
            // Set the section directly and navigate to settings
            selectedSettingsSection = .device
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedIndex = SidebarNavItem.settings.rawValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToTaskSettings)) { _ in
            // Navigate to settings > general, then developer settings will open via SettingsContentView listener
            selectedSettingsSection = .general
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
        .onChange(of: selectedIndex) { oldValue, newValue in
            // Track the previous index when navigating to settings
            if newValue == SidebarNavItem.settings.rawValue && oldValue != SidebarNavItem.settings.rawValue {
                previousIndexBeforeSettings = oldValue
            }
            // Only auto-refresh stores when their pages are visible
            updateStoreActivity(for: newValue)
        }
        .onAppear {
            updateStoreActivity(for: selectedIndex)
        }
    }
}

#Preview {
    DesktopHomeView()
}
