import SwiftUI

// MARK: - Navigation Item Model
enum SidebarNavItem: Int, CaseIterable {
    case conversations = 0
    case chat = 1
    case memories = 2
    case tasks = 3
    case focus = 4
    case advice = 5
    case rewind = 6
    case apps = 7
    case settings = 8
    case permissions = 9

    var title: String {
        switch self {
        case .conversations: return "Conversations"
        case .chat: return "Chat"
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
        [.conversations, .chat, .memories, .tasks, .focus, .advice, .rewind, .apps]
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
                        NavItemView(
                            icon: item.icon,
                            label: item.title,
                            isSelected: selectedIndex == item.rawValue,
                            isCollapsed: isCollapsed,
                            iconWidth: iconWidth,
                            badge: item == .advice ? adviceStorage.unreadCount : 0,
                            statusColor: item == .focus ? focusStatusColor : nil,
                            onTap: { selectedIndex = item.rawValue }
                        )
                    }

                    Spacer()

                    // Subscription upgrade banner
                    upgradeToPro

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
            }
            .frame(width: currentWidth + dragOffset)
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
                if let logoImage = NSImage(contentsOf: Bundle.module.url(forResource: "herologo", withExtension: "png")!) {
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
    private var upgradeToPro: some View {
        Button(action: {
            if let url = URL(string: "https://omi.me/pricing") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 17))
                    .foregroundColor(.white)
                    .frame(width: iconWidth)

                if !isCollapsed {
                    Text("Upgrade to Pro")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.purpleGradient)
            )
        }
        .buttonStyle(.plain)
        .help("Upgrade to Pro")
    }

    // MARK: - Get Omi Widget
    private var getOmiWidget: some View {
        Button(action: {
            if let url = URL(string: "https://www.omi.me") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                // Omi device image
                if let deviceUrl = Bundle.module.url(forResource: "omi-with-rope-no-padding", withExtension: "webp"),
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
    private var permissionWarningButton: some View {
        Button(action: {
            selectedIndex = SidebarNavItem.permissions.rawValue
        }) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17))
                    .foregroundColor(OmiColors.warning)
                    .frame(width: iconWidth)

                if !isCollapsed {
                    Text("Permissions")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.warning)

                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(OmiColors.warning.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(OmiColors.warning.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
        .help(isCollapsed ? "Permissions missing" : "")
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
        Button(action: onTap) {
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected
                          ? OmiColors.backgroundTertiary.opacity(0.8)
                          : (isHovered ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.bottom, 2)
        .help(isCollapsed ? label : "")
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
        Button(action: onTap) {
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? OmiColors.backgroundTertiary.opacity(0.5) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .padding(.bottom, 2)
        .help(isCollapsed ? label : "")
    }
}
