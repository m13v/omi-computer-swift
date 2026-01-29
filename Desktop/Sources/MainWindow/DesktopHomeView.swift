import SwiftUI

struct DesktopHomeView: View {
    @StateObject private var appState = AppState()
    @State private var selectedIndex: Int = 0
    @State private var isSidebarCollapsed: Bool = false

    var body: some View {
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
                        ConversationsPage()
                    case 1:
                        ChatPage()
                    case 2:
                        MemoriesPage()
                    case 3:
                        TasksPage()
                    case 4:
                        AppsPage()
                    default:
                        ConversationsPage()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .padding(12)
        }
        .background(OmiColors.backgroundPrimary)
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
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
}

#Preview {
    DesktopHomeView()
}
