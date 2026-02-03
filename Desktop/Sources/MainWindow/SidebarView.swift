import SwiftUI

// MARK: - Navigation Item Model
enum SidebarNavItem: Int, CaseIterable {
    case dashboard = 0
    case conversations = 1
    case chat = 2
    case memories = 3
    case tasks = 4
    case focus = 5
    case advice = 6
    case rewind = 7
    case apps = 8
    case settings = 9
    case permissions = 10

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .conversations: return "Conversations"
        case .chat: return "AI chat"
        case .memories: return "Memories"
        case .tasks: return "Tasks"
        case .focus: return "Focus"
        case .advice: return "Advice"
        case .rewind: return "Rewind"
        case .apps: return "Apps"
        case .settings: return "Settings"
        case .permissions: return "Permissions"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .conversations: return "text.bubble.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .memories: return "brain.head.profile"
        case .tasks: return "checkmark.square.fill"
        case .focus: return "eye.fill"
        case .advice: return "lightbulb.fill"
        case .rewind: return "clock.arrow.circlepath"
        case .apps: return "square.grid.2x2.fill"
        case .settings: return "gearshape.fill"
        case .permissions: return "exclamationmark.triangle.fill"
        }
    }

    /// Items shown in the main navigation (top section)
    static var mainItems: [SidebarNavItem] {
        [.dashboard, .conversations, .chat, .memories, .tasks, .rewind, .apps]
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    @Binding var selectedIndex: Int
    @Binding var isCollapsed: Bool
    @ObservedObject var appState: AppState
    @ObservedObject private var adviceStorage = AdviceStorage.shared
    @ObservedObject private var focusStorage = FocusStorage.shared

    // State for Get Omi Widget
    @AppStorage("showGetOmiWidget") private var showGetOmiWidget = true

    // Toggle states for quick controls
    @AppStorage("screenAnalysisEnabled") private var screenAnalysisEnabled = true
    @State private var isMonitoring = false
    @State private var isTogglingMonitoring = false
    @State private var isTogglingTranscription = false

    // Drag state
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false

    // Constants
    private let expandedWidth: CGFloat = 260
    private let collapsedWidth: CGFloat = 64
    private let iconWidth: CGFloat = 20  // Fixed width for all icons

    private var currentWidth: CGFloat {
        isCollapsed ? collapsedWidth : expandedWidth
    }

    /// Color for focus status indicator (green = focused, orange = distracted, nil = no status)
    private var focusStatusColor: Color? {
        guard let status = focusStorage.currentStatus else { return nil }
        return status == .focused ? Color.green : Color.orange
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                // Collapse button at top
                collapseButton
                    .padding(.top, 12)
                    .padding(.horizontal, isCollapsed ? 8 : 16)

                // Logo section
                logoSection

                Spacer().frame(height: 8)

                // Main navigation section
                VStack(alignment: .leading, spacing: 0) {
                    // Main navigation items
                    ForEach(SidebarNavItem.mainItems, id: \.rawValue) { item in
                        if item == .conversations {
                            // Conversations with transcription toggle
                            NavItemWithToggleView(
                                icon: item.icon,
                                label: item.title,
                                isSelected: selectedIndex == item.rawValue,
                                isCollapsed: isCollapsed,
                                iconWidth: iconWidth,
                                isToggleOn: appState.isTranscribing,
                                isToggling: isTogglingTranscription,
                                onTap: {
                                    selectedIndex = item.rawValue
                                    AnalyticsManager.shared.tabChanged(tabName: item.title)
                                },
                                onToggle: { enabled in
                                    toggleTranscription(enabled: enabled)
                                }
                            )
                        } else if item == .rewind {
                            // Rewind with screen capture toggle
                            NavItemWithToggleView(
                                icon: item.icon,
                                label: item.title,
                                isSelected: selectedIndex == item.rawValue,
                                isCollapsed: isCollapsed,
                                iconWidth: iconWidth,
                                isToggleOn: isMonitoring,
                                isToggling: isTogglingMonitoring,
                                onTap: {
                                    selectedIndex = item.rawValue
                                    AnalyticsManager.shared.tabChanged(tabName: item.title)
                                },
                                onToggle: { enabled in
                                    toggleMonitoring(enabled: enabled)
                                }
                            )
                        } else {
                            NavItemView(
                                icon: item.icon,
                                label: item.title,
                                isSelected: selectedIndex == item.rawValue,
                                isCollapsed: isCollapsed,
                                iconWidth: iconWidth,
                                badge: item == .advice ? adviceStorage.unreadCount : 0,
                                statusColor: item == .focus ? focusStatusColor : nil,
                                onTap: {
                                    selectedIndex = item.rawValue
                                    AnalyticsManager.shared.tabChanged(tabName: item.title)
                                }
                            )
                        }
                    }

                    Spacer()

                    // Subscription upgrade banner
                    // upgradeToPro

                    // Get Omi Device widget
                    if showGetOmiWidget {
                        Spacer().frame(height: 12)
                        getOmiWidget
                    }

                    Spacer().frame(height: 16)

                    // Divider before secondary items
                    Rectangle()
                        .fill(OmiColors.backgroundTertiary.opacity(0.5))
                        .frame(height: 1)

                    Spacer().frame(height: 12)

                    // Permission warning (if any permissions missing)
                    if appState.hasMissingPermissions {
                        permissionWarningButton
                    }

                    // Secondary navigation items
                    BottomNavItemView(
                        icon: "gift.fill",
                        label: "Refer a Friend",
                        isCollapsed: isCollapsed,
                        iconWidth: iconWidth,
                        onTap: {
                            if let url = URL(string: "https://affiliate.omi.me") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )

                    BottomNavItemView(
                        icon: "questionmark.circle.fill",
                        label: "Help",
                        isCollapsed: isCollapsed,
                        iconWidth: iconWidth,
                        onTap: {
                            if let url = URL(string: "https://help.omi.me") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    )

                    // Settings at the very bottom
                    NavItemView(
                        icon: "gearshape.fill",
                        label: "Settings",
                        isSelected: selectedIndex == SidebarNavItem.settings.rawValue,
                        isCollapsed: isCollapsed,
                        iconWidth: iconWidth,
                        onTap: { selectedIndex = SidebarNavItem.settings.rawValue }
                    )

                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, isCollapsed ? 8 : 16)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: currentWidth + dragOffset, maxHeight: .infinity, alignment: .top)
            .background(Color.clear)
            .animation(.easeInOut(duration: 0.2), value: isCollapsed)

            // Drag handle
            Rectangle()
                .fill(Color.clear)
                .frame(width: 8)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($isDragging) { _, state, _ in
                            state = true
                        }
                        .onChanged { value in
                            let newWidth = currentWidth + value.translation.width
                            if newWidth < (collapsedWidth + expandedWidth) / 2 {
                                if !isCollapsed {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCollapsed = true
                                    }
                                }
                            } else {
                                if isCollapsed {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isCollapsed = false
                                    }
                                }
                            }
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
        .frame(width: currentWidth)
        .onAppear {
            syncMonitoringState()
            appState.checkAllPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantMonitoringStateDidChange)) { _ in
            syncMonitoringState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh permissions when app becomes active (user may have changed them in System Settings)
            appState.checkAllPermissions()
        }
    }

    // MARK: - Collapse Button (at top, icon only)
    private var collapseButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCollapsed.toggle()
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17))
                    .foregroundColor(OmiColors.textTertiary)
                    .frame(width: iconWidth)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.clear)
            )
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Expand sidebar" : "Collapse sidebar")
    }

    // MARK: - Logo Section
    private var logoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 8)

            // Logo and brand name
            HStack(spacing: 12) {
                // Omi logo icon - using the herologo from Resources
                if let logoImage = NSImage(contentsOf: Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png")!) {
                    Image(nsImage: logoImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: iconWidth, height: iconWidth)
                } else {
                    // Fallback SF Symbol
                    Image(systemName: "circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(OmiColors.purplePrimary)
                        .frame(width: iconWidth)
                }

                if !isCollapsed {
                    // Brand name
                    Text("Omi")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(OmiColors.textPrimary)
                        .tracking(-0.5)

                    // Pro badge (placeholder - would check subscription status)
                    // proBadge
                }
            }
        }
        .padding(.horizontal, isCollapsed ? 20 : 28)
        .padding(.bottom, 16)
    }

    private var proBadge: some View {
        Text("Pro")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(OmiColors.purplePrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(OmiColors.purplePrimary.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(OmiColors.purplePrimary.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    // MARK: - Upgrade to Pro
//    private var upgradeToPro: some View {
//        Button(action: {
//            if let url = URL(string: "https://omi.me/pricing") {
//                NSWorkspace.shared.open(url)
//            }
//        }) {
//            HStack(spacing: 12) {
//                Image(systemName: "bolt.fill")
//                    .font(.system(size: 17))
//                    .foregroundColor(.white)
//                    .frame(width: iconWidth)
//
//                if !isCollapsed {
//                    Text("Upgrade to Pro")
//                        .font(.system(size: 14, weight: .semibold))
//                        .foregroundColor(.white)
//
//                    Spacer()
//                }
//            }
//            .padding(.horizontal, 12)
//            .padding(.vertical, 11)
//            .background(
//                RoundedRectangle(cornerRadius: 10)
//                    .fill(OmiColors.purpleGradient)
//            )
//        }
//        .buttonStyle(.plain)
//        .help("Upgrade to Pro")
//    }

    // MARK: - Get Omi Widget
    private var getOmiWidget: some View {
        Button(action: {
            if let url = URL(string: "https://www.omi.me") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                // Omi device image
                if let deviceUrl = Bundle.resourceBundle.url(forResource: "omi-with-rope-no-padding", withExtension: "webp"),
                   let deviceImage = NSImage(contentsOf: deviceUrl) {
                    Image(nsImage: deviceImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                } else {
                    // Fallback SF Symbol
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(OmiColors.purplePrimary)
                        .frame(width: iconWidth)
                }

                if !isCollapsed {
                    // Text content
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Get Omi Device")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Your wearable AI companion")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary.opacity(0.8))
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.backgroundTertiary.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(OmiColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Get Omi Device" : "")
    }

    // MARK: - Permission Warning Button

    // Check if any permission is specifically denied (not just missing)
    private var hasPermissionDenied: Bool {
        appState.isMicrophonePermissionDenied() || appState.isScreenRecordingPermissionDenied() || appState.isNotificationPermissionDenied() || appState.isAccessibilityPermissionDenied()
    }

    @State private var permissionPulse = false

    private var permissionWarningButton: some View {
        VStack(spacing: 6) {
            // Screen Recording permission (primary for Rewind)
            // Also show if ScreenCaptureKit is broken (TCC says yes but SCK says no)
            if !appState.hasScreenRecordingPermission || appState.isScreenCaptureKitBroken {
                screenRecordingPermissionRow
            }

            // Microphone permission
            if !appState.hasMicrophonePermission {
                microphonePermissionRow
            }

            // Notification permission (show if disabled OR if banners are off)
            if !appState.hasNotificationPermission || appState.isNotificationBannerDisabled {
                notificationPermissionRow
            }

            // Accessibility permission
            if !appState.hasAccessibilityPermission {
                accessibilityPermissionRow
            }
        }
        .padding(.bottom, 8)
        .onAppear {
            // Start pulsing animation when denied
            if hasPermissionDenied {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    permissionPulse = true
                }
            }
        }
        .onChange(of: hasPermissionDenied) { _, denied in
            if denied {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    permissionPulse = true
                }
            } else {
                permissionPulse = false
            }
        }
    }

    private var screenRecordingPermissionRow: some View {
        let isDenied = appState.isScreenRecordingPermissionDenied()
        let isBroken = appState.isScreenCaptureKitBroken  // TCC yes but SCK no
        let needsReset = isBroken  // Show reset when broken
        let color: Color = (isDenied || isBroken) ? .red : OmiColors.warning

        return HStack(spacing: 8) {
            Image(systemName: (isDenied || isBroken) ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: iconWidth)
                .scaleEffect(permissionPulse && (isDenied || isBroken) ? 1.1 : 1.0)

            if !isCollapsed {
                Text(isBroken ? "Screen Recording (Reset Required)" : "Screen Recording")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    if needsReset {
                        // Track reset button click
                        AnalyticsManager.shared.screenCaptureResetClicked(source: "sidebar_button")
                        // Reset and restart to fix broken ScreenCaptureKit state
                        ScreenCaptureService.resetScreenCapturePermissionAndRestart()
                    } else {
                        // Request both traditional TCC and ScreenCaptureKit permissions
                        ScreenCaptureService.requestAllScreenCapturePermissions()
                        // Also open settings for manual grant if needed
                        ScreenCaptureService.openScreenRecordingPreferences()
                    }
                }) {
                    Text(needsReset ? "Reset" : "Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(permissionPulse && (isDenied || isBroken) ? 0.25 : 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: (isDenied || isBroken) ? 2 : 1)
                )
        )
        .help(isCollapsed ? (isBroken ? "Screen Recording needs reset" : "Screen Recording permission required") : "")
    }

    private var microphonePermissionRow: some View {
        let isDenied = appState.isMicrophonePermissionDenied()
        let color: Color = isDenied ? .red : OmiColors.warning

        return HStack(spacing: 8) {
            Image(systemName: isDenied ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: iconWidth)
                .scaleEffect(permissionPulse && isDenied ? 1.1 : 1.0)

            if !isCollapsed {
                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    if isDenied {
                        // Go to permissions page for reset options
                        selectedIndex = SidebarNavItem.permissions.rawValue
                    } else {
                        // Request permission directly
                        appState.requestMicrophonePermission()
                    }
                }) {
                    Text(isDenied ? "Fix" : "Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(permissionPulse && isDenied ? 0.25 : 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: isDenied ? 2 : 1)
                )
        )
        .help(isCollapsed ? "Microphone permission required" : "")
    }

    private var notificationPermissionRow: some View {
        let isDenied = appState.isNotificationPermissionDenied()
        let isBannerDisabled = appState.isNotificationBannerDisabled
        let needsAttention = isDenied || isBannerDisabled
        let color: Color = needsAttention ? OmiColors.warning : OmiColors.warning

        return HStack(spacing: 8) {
            Image(systemName: isDenied ? "bell.slash.fill" : (isBannerDisabled ? "bell.badge.slash.fill" : "bell.fill"))
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: iconWidth)
                .scaleEffect(permissionPulse && needsAttention ? 1.1 : 1.0)

            if !isCollapsed {
                Text(isBannerDisabled ? "Banners Off" : "Notifications")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    // Always open settings - user needs to configure notification style
                    appState.openNotificationPreferences()
                }) {
                    Text("Fix")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(permissionPulse && isDenied ? 0.25 : 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: isDenied ? 2 : 1)
                )
        )
        .help(isCollapsed ? "Notification permission required" : "")
    }

    private var accessibilityPermissionRow: some View {
        let isDenied = appState.isAccessibilityPermissionDenied()
        let color: Color = isDenied ? .red : OmiColors.warning

        return HStack(spacing: 8) {
            Image(systemName: isDenied ? "hand.raised.slash.fill" : "hand.raised.fill")
                .font(.system(size: 15))
                .foregroundColor(color)
                .frame(width: iconWidth)
                .scaleEffect(permissionPulse && isDenied ? 1.1 : 1.0)

            if !isCollapsed {
                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .lineLimit(1)

                Spacer()

                Button(action: {
                    // Trigger the permission request, which will also open settings
                    appState.triggerAccessibilityPermission()
                }) {
                    Text(isDenied ? "Fix" : "Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(color)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(permissionPulse && isDenied ? 0.25 : 0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.3), lineWidth: isDenied ? 2 : 1)
                )
        )
        .help(isCollapsed ? "Accessibility permission required" : "")
    }

    // MARK: - Toggle Handlers

    private func toggleTranscription(enabled: Bool) {
        // Check microphone permission
        if enabled && !appState.hasMicrophonePermission {
            return
        }

        // Show loading immediately
        isTogglingTranscription = true

        // Track setting change
        AnalyticsManager.shared.settingToggled(setting: "transcription", enabled: enabled)

        // Persist the setting first for immediate feedback
        AssistantSettings.shared.transcriptionEnabled = enabled

        if enabled {
            appState.startTranscription()
        } else {
            appState.stopTranscription()
        }

        // Small delay to show the loading state visually
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isTogglingTranscription = false
        }
    }

    private func toggleMonitoring(enabled: Bool) {
        if enabled && !ProactiveAssistantsPlugin.shared.hasScreenRecordingPermission {
            isMonitoring = false
            // Request both traditional TCC and ScreenCaptureKit permissions
            ScreenCaptureService.requestAllScreenCapturePermissions()
            ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
            return
        }

        // Show loading immediately and update state optimistically
        isTogglingMonitoring = true
        isMonitoring = enabled

        // Track setting change
        AnalyticsManager.shared.settingToggled(setting: "monitoring", enabled: enabled)

        // Persist the setting
        screenAnalysisEnabled = enabled
        AssistantSettings.shared.screenAnalysisEnabled = enabled

        if enabled {
            ProactiveAssistantsPlugin.shared.startMonitoring { success, _ in
                DispatchQueue.main.async {
                    isTogglingMonitoring = false
                    if !success {
                        // Revert on failure
                        isMonitoring = false
                    }
                }
            }
        } else {
            ProactiveAssistantsPlugin.shared.stopMonitoring()
            // Small delay to show the loading state visually
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTogglingMonitoring = false
            }
        }
    }

    private func syncMonitoringState() {
        isMonitoring = ProactiveAssistantsPlugin.shared.isMonitoring
    }
}

// MARK: - Nav Item View
struct NavItemView: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let isCollapsed: Bool
    let iconWidth: CGFloat
    var badge: Int = 0
    var statusColor: Color? = nil
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(isSelected ? OmiColors.textPrimary : OmiColors.textTertiary)
                    .frame(width: iconWidth)

                // Badge on icon when collapsed
                if isCollapsed && badge > 0 {
                    Circle()
                        .fill(OmiColors.purplePrimary)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }

                // Status indicator when collapsed (for Focus)
                if isCollapsed, let color = statusColor {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }

            if !isCollapsed {
                Text(label)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? OmiColors.textPrimary : OmiColors.textSecondary)

                Spacer()

                // Status indicator when expanded (for Focus)
                if let color = statusColor {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }

                // Badge count when expanded
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(OmiColors.purplePrimary)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? OmiColors.backgroundTertiary.opacity(0.8)
                      : (isHovered ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear))
        )
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.bottom, 2)
        .help(isCollapsed ? label : "")
    }
}

// MARK: - Nav Item With Toggle View
struct NavItemWithToggleView: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let isCollapsed: Bool
    let iconWidth: CGFloat
    let isToggleOn: Bool
    let isToggling: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    @State private var isHovered = false

    /// Icon color based on toggle state
    private var iconColor: Color {
        if isToggleOn {
            return isSelected ? OmiColors.textPrimary : OmiColors.textTertiary
        } else {
            return OmiColors.error
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Main nav item - tappable area
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundColor(iconColor)
                        .frame(width: iconWidth)

                    // Status indicator when collapsed
                    if isCollapsed {
                        Circle()
                            .fill(isToggleOn ? OmiColors.purplePrimary : OmiColors.error)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
                }

                if !isCollapsed {
                    Text(label)
                        .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                        .foregroundColor(isSelected ? OmiColors.textPrimary : OmiColors.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 4)
                }
            }
            .padding(.leading, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }

            // Toggle (only when expanded)
            if !isCollapsed {
                if isToggling {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 40, height: 20)
                        .padding(.trailing, 8)
                } else {
                    SidebarToggle(isOn: Binding(
                        get: { isToggleOn },
                        set: { onToggle($0) }
                    ))
                    .padding(.trailing, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? OmiColors.backgroundTertiary.opacity(0.8)
                      : (isHovered ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.bottom, 2)
        .help(isCollapsed ? "\(label) (\(isToggleOn ? "On" : "Off"))" : "")
    }
}

// MARK: - Custom Sidebar Toggle
struct SidebarToggle: View {
    @Binding var isOn: Bool

    private let width: CGFloat = 36
    private let height: CGFloat = 20
    private let circleSize: CGFloat = 16
    private let padding: CGFloat = 2

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track - purple when on, red when off
            Capsule()
                .fill(isOn ? OmiColors.purplePrimary : OmiColors.error)
                .frame(width: width, height: height)

            // Thumb
            Circle()
                .fill(Color.white)
                .frame(width: circleSize, height: circleSize)
                .padding(padding)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .onTapGesture {
            isOn.toggle()
        }
    }
}

// MARK: - Bottom Nav Item View
struct BottomNavItemView: View {
    let icon: String
    let label: String
    let isCollapsed: Bool
    let iconWidth: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(OmiColors.textTertiary)
                .frame(width: iconWidth)

            if !isCollapsed {
                Text(label)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isHovered ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear)
        )
        .onTapGesture {
            onTap()
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.bottom, 2)
        .help(isCollapsed ? label : "")
    }
}
