import Foundation
import SwiftUI
import Combine

/// View model for the Rewind page
@MainActor
class RewindViewModel: ObservableObject {
    // MARK: - Published State

    @Published var screenshots: [Screenshot] = []
    @Published var selectedScreenshot: Screenshot? = nil
    @Published var searchQuery: String = ""
    @Published var selectedApp: String? = nil
    @Published var selectedDate: Date = Date()
    @Published var availableApps: [String] = []

    @Published var isLoading = false
    @Published var isSearching = false
    @Published var errorMessage: String? = nil

    @Published var stats: (total: Int, indexed: Int, storageSize: Int64)? = nil

    /// The active search query (trimmed, non-empty) for highlighting
    @Published var activeSearchQuery: String? = nil

    // MARK: - Private State

    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        // Debounce search queries
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] query in
                Task { await self?.performSearch(query: query) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Loading

    func loadInitialData() async {
        isLoading = true
        errorMessage = nil

        do {
            // Initialize the indexer if needed
            try await RewindIndexer.shared.initialize()

            // Load recent screenshots
            screenshots = try await RewindDatabase.shared.getRecentScreenshots(limit: 100)

            // Load available apps for filtering
            availableApps = try await RewindDatabase.shared.getUniqueAppNames()

            // Load stats
            if let indexerStats = await RewindIndexer.shared.getStats() {
                stats = indexerStats
            }

        } catch {
            errorMessage = error.localizedDescription
            logError("RewindViewModel: Failed to load initial data: \(error)")
        }

        isLoading = false
    }

    func refresh() async {
        await loadInitialData()
    }

    // MARK: - Search

    private func performSearch(query: String) async {
        // Cancel any existing search
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            // Reset to recent screenshots
            isSearching = false
            activeSearchQuery = nil
            do {
                screenshots = try await RewindDatabase.shared.getRecentScreenshots(limit: 100)
            } catch {
                logError("RewindViewModel: Failed to load recent screenshots: \(error)")
            }
            return
        }

        isSearching = true
        activeSearchQuery = trimmedQuery

        searchTask = Task {
            do {
                let results = try await RewindDatabase.shared.search(
                    query: trimmedQuery,
                    appFilter: selectedApp,
                    limit: 100
                )

                if !Task.isCancelled {
                    screenshots = results
                }
            } catch {
                if !Task.isCancelled {
                    logError("RewindViewModel: Search failed: \(error)")
                }
            }

            if !Task.isCancelled {
                isSearching = false
            }
        }
    }

    // MARK: - Filtering

    func filterByApp(_ app: String?) async {
        selectedApp = app

        if !searchQuery.isEmpty {
            await performSearch(query: searchQuery)
        } else {
            await loadScreenshotsForDate(selectedDate)
        }
    }

    func filterByDate(_ date: Date) async {
        selectedDate = date
        await loadScreenshotsForDate(date)
    }

    private func loadScreenshotsForDate(_ date: Date) async {
        isLoading = true

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        do {
            var results = try await RewindDatabase.shared.getScreenshots(
                from: startOfDay,
                to: endOfDay,
                limit: 500
            )

            // Apply app filter if set
            if let app = selectedApp {
                results = results.filter { $0.appName == app }
            }

            screenshots = results

        } catch {
            logError("RewindViewModel: Failed to load screenshots for date: \(error)")
        }

        isLoading = false
    }

    // MARK: - Screenshot Selection

    func selectScreenshot(_ screenshot: Screenshot) {
        selectedScreenshot = screenshot
    }

    func selectNextScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex > 0 else { return }

        selectedScreenshot = screenshots[currentIndex - 1]
    }

    func selectPreviousScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex < screenshots.count - 1 else { return }

        selectedScreenshot = screenshots[currentIndex + 1]
    }

    // MARK: - Search Result Helpers

    /// Get a context snippet for the current search query on a screenshot
    func contextSnippet(for screenshot: Screenshot) -> String? {
        guard let query = activeSearchQuery else { return nil }
        return screenshot.contextSnippet(for: query)
    }

    /// Get matching text blocks for highlighting
    func matchingBlocks(for screenshot: Screenshot) -> [OCRTextBlock] {
        guard let query = activeSearchQuery else { return [] }
        return screenshot.matchingBlocks(for: query)
    }

    // MARK: - Delete

    func deleteScreenshot(_ screenshot: Screenshot) async {
        guard let id = screenshot.id else { return }

        do {
            // Delete from database (returns image path)
            if let imagePath = try await RewindDatabase.shared.deleteScreenshot(id: id) {
                // Delete from storage
                try await RewindStorage.shared.deleteScreenshot(relativePath: imagePath)
            }

            // Remove from local array
            screenshots.removeAll { $0.id == id }

            // Clear selection if deleted
            if selectedScreenshot?.id == id {
                selectedScreenshot = nil
            }

        } catch {
            logError("RewindViewModel: Failed to delete screenshot: \(error)")
        }
    }

    // MARK: - Stats

    func refreshStats() async {
        if let indexerStats = await RewindIndexer.shared.getStats() {
            stats = indexerStats
        }
    }
}
