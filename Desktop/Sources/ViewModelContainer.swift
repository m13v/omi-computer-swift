import SwiftUI

/// Central container that holds all ViewModels for eager data loading
/// and keeps views alive across tab switches
@MainActor
class ViewModelContainer: ObservableObject {
    // ViewModels for each page
    let dashboardViewModel = DashboardViewModel()
    let tasksViewModel = TasksViewModel()
    let appProvider = AppProvider()
    let memoriesViewModel = MemoriesViewModel()
    let chatProvider = ChatProvider()

    // Loading state
    @Published var isInitialLoadComplete = false
    @Published var isLoading = false

    /// Load all data in parallel at app launch
    func loadAllData() async {
        guard !isLoading else { return }
        isLoading = true

        log("ViewModelContainer: Starting eager data load for all pages")

        // Load all data in parallel
        async let dashboard: Void = dashboardViewModel.loadDashboardData()
        async let tasks: Void = tasksViewModel.loadTasks()
        async let apps: Void = appProvider.fetchApps()
        async let memories: Void = memoriesViewModel.loadMemories()
        async let chat: Void = chatProvider.initialize()

        // Wait for all to complete
        _ = await (dashboard, tasks, apps, memories, chat)

        isInitialLoadComplete = true
        isLoading = false

        log("ViewModelContainer: Eager data load complete")
    }
}
