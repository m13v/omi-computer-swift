import SwiftUI

/// State management for apps/plugins functionality
@MainActor
class AppProvider: ObservableObject {
    @Published var apps: [OmiApp] = []
    @Published var popularApps: [OmiApp] = []
    @Published var enabledApps: [OmiApp] = []
    @Published var chatApps: [OmiApp] = []
    @Published var categories: [OmiAppCategory] = []
    @Published var capabilities: [OmiAppCapability] = []

    @Published var isLoading = false
    @Published var isSearching = false
    @Published var appLoadingStates: [String: Bool] = [:]

    @Published var searchQuery = ""
    @Published var selectedCategory: String?
    @Published var selectedCapability: String?
    @Published var showInstalledOnly = false

    @Published var errorMessage: String?

    private let apiClient = APIClient.shared

    // MARK: - Fetch Methods

    /// Fetch all apps data (popular, categories, etc.)
    func fetchApps() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            // Fetch in parallel
            async let appsTask = apiClient.getApps()
            async let popularTask = apiClient.getPopularApps()
            async let categoriesTask = apiClient.getAppCategories()
            async let capabilitiesTask = apiClient.getAppCapabilities()

            let (fetchedApps, fetchedPopular, fetchedCategories, fetchedCapabilities) = try await (
                appsTask,
                popularTask,
                categoriesTask,
                capabilitiesTask
            )

            apps = fetchedApps
            popularApps = fetchedPopular
            categories = fetchedCategories
            capabilities = fetchedCapabilities

            updateDerivedLists()

            log("Fetched \(apps.count) apps, \(popularApps.count) popular")
        } catch {
            logError("Failed to fetch apps", error: error)
            errorMessage = "Failed to load apps: \(error.localizedDescription)"
        }
    }

    /// Search apps with current filters
    func searchApps() async {
        guard !searchQuery.isEmpty || selectedCategory != nil || selectedCapability != nil || showInstalledOnly else {
            // Reset to default view
            await fetchApps()
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            apps = try await apiClient.searchApps(
                query: searchQuery.isEmpty ? nil : searchQuery,
                category: selectedCategory,
                capability: selectedCapability,
                installedOnly: showInstalledOnly
            )
            updateDerivedLists()
        } catch {
            logError("Failed to search apps", error: error)
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    /// Fetch user's enabled apps
    func fetchEnabledApps() async {
        do {
            enabledApps = try await apiClient.getEnabledApps()
            chatApps = enabledApps.filter { $0.worksWithChat }
        } catch {
            logError("Failed to fetch enabled apps", error: error)
        }
    }

    // MARK: - App Management

    /// Toggle app enabled state
    func toggleApp(_ app: OmiApp) async {
        appLoadingStates[app.id] = true
        defer { appLoadingStates[app.id] = false }

        do {
            if app.enabled {
                try await apiClient.disableApp(appId: app.id)
            } else {
                try await apiClient.enableApp(appId: app.id)
            }

            // Update local state
            if let index = apps.firstIndex(where: { $0.id == app.id }) {
                apps[index].enabled.toggle()
            }
            if let index = popularApps.firstIndex(where: { $0.id == app.id }) {
                popularApps[index].enabled.toggle()
            }

            updateDerivedLists()

            log("Toggled app \(app.id) to enabled=\(!app.enabled)")
        } catch {
            logError("Failed to toggle app", error: error)
            errorMessage = "Failed to \(app.enabled ? "disable" : "enable") app"
        }
    }

    /// Enable an app
    func enableApp(_ app: OmiApp) async {
        guard !app.enabled else { return }
        await toggleApp(app)
    }

    /// Disable an app
    func disableApp(_ app: OmiApp) async {
        guard app.enabled else { return }
        await toggleApp(app)
    }

    // MARK: - Helpers

    /// Check if an app is currently loading
    func isAppLoading(_ appId: String) -> Bool {
        appLoadingStates[appId] ?? false
    }

    /// Update derived lists from main apps list
    private func updateDerivedLists() {
        enabledApps = apps.filter { $0.enabled }
        chatApps = enabledApps.filter { $0.worksWithChat }
    }

    /// Get apps filtered by category
    func apps(forCategory category: String) -> [OmiApp] {
        apps.filter { $0.category == category }
    }

    /// Get apps filtered by capability
    func apps(forCapability capability: String) -> [OmiApp] {
        apps.filter { $0.capabilities.contains(capability) }
    }

    /// Clear search and filters
    func clearFilters() {
        searchQuery = ""
        selectedCategory = nil
        selectedCapability = nil
        showInstalledOnly = false
    }
}
