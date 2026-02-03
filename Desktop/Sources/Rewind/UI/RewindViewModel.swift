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

    /// Time window in seconds for grouping search results
    var searchGroupingTimeWindow: TimeInterval = 30

    /// Grouped search results (computed from screenshots when searching)
    var groupedSearchResults: [SearchResultGroup] {
        guard activeSearchQuery != nil else { return [] }
        return screenshots.groupedByContext(timeWindowSeconds: searchGroupingTimeWindow)
    }

    /// Total number of individual screenshots across all groups
    var totalScreenshotCount: Int {
        screenshots.count
    }

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

        } catch {
            errorMessage = error.localizedDescription
            logError("RewindViewModel: Failed to load initial data: \(error)")
        }

        isLoading = false

        // Load stats asynchronously (includes storage size calculation which can be slow)
        Task {
            if let indexerStats = await RewindIndexer.shared.getStats() {
                stats = indexerStats
            }
        }
    }

    func refresh() async {
        await loadInitialData()
    }

    // MARK: - Search

    /// Whether to apply date filter to search (when user explicitly selected a date)
    @Published var applyDateFilterToSearch: Bool = false

    private func performSearch(query: String) async {
        // Cancel any existing search
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedQuery.isEmpty {
            // Reset to recent screenshots or date-filtered view
            isSearching = false
            activeSearchQuery = nil
            if applyDateFilterToSearch {
                await loadScreenshotsForDate(selectedDate)
            } else {
                do {
                    screenshots = try await RewindDatabase.shared.getRecentScreenshots(limit: 100)
                } catch {
                    logError("RewindViewModel: Failed to load recent screenshots: \(error)")
                }
            }
            return
        }

        isSearching = true
        activeSearchQuery = trimmedQuery

        // Track rewind search
        AnalyticsManager.shared.rewindSearchPerformed(queryLength: trimmedQuery.count)

        // Calculate date range if date filter is applied
        var startDate: Date? = nil
        var endDate: Date? = nil
        if applyDateFilterToSearch {
            let calendar = Calendar.current
            startDate = calendar.startOfDay(for: selectedDate)
            endDate = calendar.date(byAdding: .day, value: 1, to: startDate!)
        }

        searchTask = Task {
            do {
                let results = try await RewindDatabase.shared.search(
                    query: trimmedQuery,
                    appFilter: selectedApp,
                    startDate: startDate,
                    endDate: endDate,
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
        applyDateFilterToSearch = true

        if !searchQuery.isEmpty {
            await performSearch(query: searchQuery)
        } else {
            await loadScreenshotsForDate(date)
        }
    }

    /// Clear date filter to search all time
    func clearDateFilter() async {
        applyDateFilterToSearch = false
        if !searchQuery.isEmpty {
            await performSearch(query: searchQuery)
        } else {
            do {
                screenshots = try await RewindDatabase.shared.getRecentScreenshots(limit: 100)
            } catch {
                logError("RewindViewModel: Failed to load recent screenshots: \(error)")
            }
        }
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
        AnalyticsManager.shared.rewindScreenshotViewed(timestamp: screenshot.timestamp)
    }

    func selectNextScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex > 0 else { return }

        selectedScreenshot = screenshots[currentIndex - 1]
        AnalyticsManager.shared.rewindTimelineNavigated(direction: "next")
    }

    func selectPreviousScreenshot() {
        guard let current = selectedScreenshot,
              let currentIndex = screenshots.firstIndex(where: { $0.id == current.id }),
              currentIndex < screenshots.count - 1 else { return }

        selectedScreenshot = screenshots[currentIndex + 1]
        AnalyticsManager.shared.rewindTimelineNavigated(direction: "previous")
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
            // Delete from database (returns storage info)
            if let result = try await RewindDatabase.shared.deleteScreenshot(id: id) {
                // Delete legacy JPEG if present
                if let imagePath = result.imagePath {
                    try await RewindStorage.shared.deleteScreenshot(relativePath: imagePath)
                }
                // Delete video chunk if this was the last frame in it
                if result.isLastFrameInChunk, let videoChunkPath = result.videoChunkPath {
                    try await RewindStorage.shared.deleteVideoChunk(relativePath: videoChunkPath)
                }
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
