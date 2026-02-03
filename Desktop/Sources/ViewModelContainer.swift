import SwiftUI

/// Central container that holds all ViewModels for eager data loading
/// and keeps views alive across tab switches
@MainActor
class ViewModelContainer: ObservableObject {
    // Shared stores (single source of truth)
    let tasksStore = TasksStore.shared

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

        let timer = PerfTimer("ViewModelContainer.loadAllData", logCPU: true)
        logPerf("DATA LOAD: Starting eager data load for all pages", cpu: true)

        // Load shared stores first (both Dashboard and Tasks use these)
        async let tasks: Void = measurePerfAsync("DATA LOAD: TasksStore") { await tasksStore.loadTasks() }

        // Load page-specific data in parallel
        async let dashboard: Void = measurePerfAsync("DATA LOAD: Dashboard") { await dashboardViewModel.loadDashboardData() }
        async let apps: Void = measurePerfAsync("DATA LOAD: Apps") { await appProvider.fetchApps() }
        async let memories: Void = measurePerfAsync("DATA LOAD: Memories") { await memoriesViewModel.loadMemories() }
        async let chat: Void = measurePerfAsync("DATA LOAD: Chat") { await chatProvider.initialize() }

        // Wait for all to complete
        _ = await (tasks, dashboard, apps, memories, chat)

        isInitialLoadComplete = true
        isLoading = false

        timer.stop()
        logPerf("DATA LOAD: Complete - all pages loaded", cpu: true)
    }
}
