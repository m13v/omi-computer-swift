import SwiftUI
import AppKit

/// Main Rewind page - Timeline-first view with integrated search
/// The timeline is the primary interface, with search results highlighted inline
struct RewindPage: View {
    @StateObject private var viewModel = RewindViewModel()

    @State private var currentIndex: Int = 0
    @State private var currentImage: NSImage?
    @State private var isLoadingFrame = false
    @State private var isPlaying = false
    @State private var playbackSpeed: Double = 1.0
    @State private var playbackTimer: Timer?

    @State private var searchViewMode: SearchViewMode? = nil
    @State private var selectedGroupIndex: Int = 0
    @FocusState private var isSearchFocused: Bool

    enum SearchViewMode {
        case results  // Full-screen search results
        case timeline // Timeline with search highlights
    }

    /// Whether we're in search mode (has query or active search)
    private var isInSearchMode: Bool {
        viewModel.activeSearchQuery != nil || !viewModel.searchQuery.isEmpty
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            if viewModel.isLoading && viewModel.screenshots.isEmpty && viewModel.activeSearchQuery == nil {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else {
                // Main content with persistent search field
                VStack(spacing: 0) {
                    // Unified top bar - search field is always here
                    unifiedTopBar

                    // Content area changes based on mode
                    if isInSearchMode {
                        if viewModel.screenshots.isEmpty {
                            noSearchResultsView
                        } else if searchViewMode == .timeline {
                            timelineWithSearch
                        } else {
                            fullScreenResultsView
                        }
                    } else if viewModel.screenshots.isEmpty {
                        emptyState
                    } else {
                        // Normal timeline view (without top bar, since we have unified one)
                        timelineContentBody
                    }
                }
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
        .onChange(of: viewModel.screenshots) { _, screenshots in
            // Reset indices when screenshots change
            if !screenshots.isEmpty && currentIndex >= screenshots.count {
                currentIndex = 0
            }
            selectedGroupIndex = 0
            // Load frame for current position
            Task { await loadCurrentFrame() }
        }
        .onChange(of: viewModel.activeSearchQuery) { oldQuery, newQuery in
            // When search becomes active, default to results view
            if oldQuery == nil && newQuery != nil {
                searchViewMode = .results
                selectedGroupIndex = 0
            }
            // When search is cleared, reset view mode
            if newQuery == nil {
                searchViewMode = nil
                selectedGroupIndex = 0
            }
        }
        // Global keyboard handlers
        .onKeyPress(.escape) {
            // Timeline mode → go back to results list
            if searchViewMode == .timeline {
                searchViewMode = .results
                return .handled
            }
            // In search mode → clear search
            if viewModel.activeSearchQuery != nil {
                viewModel.searchQuery = ""
                searchViewMode = nil
                return .handled
            }
            if isSearchFocused {
                isSearchFocused = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            // Arrow keys only work in timeline mode
            if searchViewMode != .results {
                previousFrame()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if searchViewMode != .results {
                nextFrame()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow) {
            // Up/down navigate search result groups
            if searchViewMode == .results {
                if selectedGroupIndex > 0 {
                    selectedGroupIndex -= 1
                    return .handled
                }
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if searchViewMode == .results {
                let groups = viewModel.groupedSearchResults
                if selectedGroupIndex < groups.count - 1 {
                    selectedGroupIndex += 1
                    return .handled
                }
            }
            return .ignored
        }
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
        // Global scroll wheel handler - works anywhere on the page
        .background(
            ScrollWheelCaptureView { delta in
                handleScrollWheel(delta: delta)
            }
        )
    }

    // Handle scroll wheel to move playhead
    private func handleScrollWheel(delta: CGFloat) {
        guard !activeScreenshots.isEmpty else { return }
        guard searchViewMode != .results else { return } // Don't scroll in results list view

        let sensitivity: CGFloat = 3.0
        let framesToMove = Int(-delta * sensitivity)

        if framesToMove != 0 {
            let newIndex = max(0, min(activeScreenshots.count - 1, currentIndex + framesToMove))
            if newIndex != currentIndex {
                seekToIndex(newIndex)
            }
        }
    }

    // MARK: - No Search Results

    private var noSearchResultsView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.3))

            if viewModel.isSearching {
                Text("Searching...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            } else {
                Text("No results found")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))

                Text("Try a different search term")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }

            Spacer()
        }
    }

    // MARK: - Unified Top Bar (persistent search field)

    private var unifiedTopBar: some View {
        HStack(spacing: 12) {
            // Left side: Back button (search timeline mode) or Rewind logo (other modes)
            if isInSearchMode && searchViewMode == .timeline {
                Button {
                    searchViewMode = .results
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Back to results")
            } else {
                // Rewind title/logo
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)

                    Text("Rewind")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    // Global hotkey hint
                    HStack(spacing: 2) {
                        Text("⌘")
                        Text("⌥")
                        Text("R")
                    }
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                    .help("Press ⌘⌥R from anywhere to open Rewind")
                }
            }

            // Search field - always present, shows results count in search mode
            searchField(showResultsCount: isInSearchMode)

            // Right side controls depend on mode
            if isInSearchMode {
                // View mode toggle for search
                HStack(spacing: 2) {
                    Button {
                        searchViewMode = .results
                        if !viewModel.screenshots.isEmpty {
                            currentIndex = 0
                            Task { await loadCurrentFrame() }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11))
                            .foregroundColor(searchViewMode == .results ? .white : .white.opacity(0.5))
                            .frame(width: 28, height: 24)
                            .background(searchViewMode == .results ? OmiColors.purplePrimary : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("List view")

                    Button {
                        if searchViewMode != .timeline && !viewModel.screenshots.isEmpty {
                            currentIndex = 0
                            Task { await loadCurrentFrame() }
                        }
                        searchViewMode = .timeline
                    } label: {
                        Image(systemName: "timeline.selection")
                            .font(.system(size: 11))
                            .foregroundColor(searchViewMode == .timeline ? .white : .white.opacity(0.5))
                            .frame(width: 28, height: 24)
                            .background(searchViewMode == .timeline ? OmiColors.purplePrimary : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Timeline view")
                }
                .padding(2)
                .background(Color.white.opacity(0.1))
                .cornerRadius(6)
            } else {
                // Timeline mode controls
                // Stats
                if let stats = viewModel.stats {
                    Text("\(stats.total) frames • \(RewindStorage.formatBytes(stats.storageSize))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }

                // Playback speed
                Menu {
                    ForEach([0.5, 1.0, 2.0, 4.0, 8.0], id: \.self) { speed in
                        Button {
                            playbackSpeed = speed
                            if isPlaying {
                                restartPlayback()
                            }
                        } label: {
                            HStack {
                                Text("\(speed, specifier: "%.1f")x")
                                if playbackSpeed == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                        Text("\(playbackSpeed, specifier: "%.1f")x")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)

                // Refresh
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isLoading)

                // Settings
                Button {
                    NotificationCenter.default.post(
                        name: .navigateToRewindSettings,
                        object: nil
                    )
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Rewind Settings")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
    }

    // MARK: - Timeline Content Body (without top bar)

    private var timelineContentBody: some View {
        VStack(spacing: 0) {
            // Main frame display
            Spacer()
            frameDisplay
            Spacer()

            // Timeline and controls at bottom
            bottomControls
        }
    }

    // MARK: - Full Screen Results View (Google-style vertical list with grouping)

    private var fullScreenResultsView: some View {
        let groups = viewModel.groupedSearchResults

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                        SearchResultGroupItem(
                            group: group,
                            index: groupIndex,
                            totalGroups: groups.count,
                            totalScreenshots: viewModel.totalScreenshotCount,
                            searchQuery: viewModel.activeSearchQuery ?? "",
                            isSelected: selectedGroupIndex == groupIndex,
                            onTap: {
                                // Set the screenshots to this group's screenshots for timeline navigation
                                selectedGroupIndex = groupIndex
                                currentIndex = 0
                                searchViewMode = .timeline
                                Task { await loadCurrentFrame() }
                            }
                        )
                        .id(groupIndex)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: selectedGroupIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    /// Screenshots for the currently selected group (used in timeline view)
    private var currentGroupScreenshots: [Screenshot] {
        let groups = viewModel.groupedSearchResults
        guard selectedGroupIndex < groups.count else { return viewModel.screenshots }
        return groups[selectedGroupIndex].screenshots
    }

    /// The active screenshot list - either group screenshots (when viewing a group) or all screenshots
    private var activeScreenshots: [Screenshot] {
        if searchViewMode == .timeline && viewModel.activeSearchQuery != nil {
            return currentGroupScreenshots
        }
        return viewModel.screenshots
    }

    // MARK: - Timeline with Search

    private var timelineWithSearch: some View {
        VStack(spacing: 0) {
            // Frame display
            Spacer()
            frameDisplay
            Spacer()

            // Timeline and controls
            bottomControls
        }
    }

    // MARK: - Unified Search Field

    private func searchField(showResultsCount: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(isSearchFocused ? OmiColors.purplePrimary : .white.opacity(0.5))

            TextField("Search your screen history...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .focused($isSearchFocused)

            if viewModel.isSearching {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
            } else if showResultsCount && !viewModel.searchQuery.isEmpty && viewModel.activeSearchQuery != nil {
                let groups = viewModel.groupedSearchResults
                let total = viewModel.totalScreenshotCount
                if groups.count == total {
                    Text("\(total) results")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("\(groups.count) groups (\(total) total)")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    searchViewMode = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSearchFocused ? OmiColors.purplePrimary.opacity(0.5) : Color.clear, lineWidth: 1)
                )
        )
    }

    // MARK: - Frame Display

    private var frameDisplay: some View {
        GeometryReader { geometry in
            if isLoadingFrame && currentImage == nil {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.2)
                    .tint(.white)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else if let image = currentImage, image.size.height > 0, image.size.width > 0, geometry.size.height > 0, geometry.size.width > 0 {
                // Calculate size to fill container while maintaining aspect ratio
                let imageAspect = image.size.width / image.size.height
                let containerAspect = geometry.size.width / geometry.size.height

                let displaySize: CGSize = {
                    if imageAspect > containerAspect {
                        // Wide image - fill width
                        let width = geometry.size.width
                        let height = width / imageAspect
                        return CGSize(width: max(1, width), height: max(1, height))
                    } else {
                        // Tall image - fill height
                        let height = geometry.size.height
                        let width = height * imageAspect
                        return CGSize(width: max(1, width), height: max(1, height))
                    }
                }()

                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .cornerRadius(4)
                        .shadow(color: .black.opacity(0.3), radius: 8)

                    // Search highlight overlays with explicit frame
                    if let query = viewModel.activeSearchQuery,
                       currentIndex < activeScreenshots.count {
                        SearchHighlightOverlay(
                            screenshot: activeScreenshots[currentIndex],
                            query: query,
                            imageSize: image.size,
                            containerSize: displaySize
                        )
                        .frame(width: displaySize.width, height: displaySize.height)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                // Log why we're showing "No frame" for debugging
                let _ = {
                    if currentImage == nil {
                        // Normal case - no image loaded yet
                    } else if let img = currentImage {
                        logError("RewindPage: Invalid frame dimensions - image=\(img.size) geometry=\(geometry.size)")
                    }
                }()
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No frame")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Bottom Controls (Compact - all on one line)

    private var bottomControls: some View {
        let screenshots = activeScreenshots

        return VStack(spacing: 8) {
            // Timeline bar
            InteractiveTimelineBar(
                screenshots: screenshots,
                currentIndex: currentIndex,
                searchResultIndices: viewModel.activeSearchQuery != nil && searchViewMode != .timeline ? Set(searchResultIndices) : nil,
                onSelect: { index in
                    seekToIndex(index)
                }
            )

            // Single compact control bar: app info | playback | position/time
            HStack(spacing: 16) {
                // Left: App icon and name
                if currentIndex < screenshots.count {
                    let screenshot = screenshots[currentIndex]
                    HStack(spacing: 6) {
                        AppIconView(appName: screenshot.appName, size: 16)
                        Text(screenshot.appName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .frame(width: 120, alignment: .leading)
                }

                Spacer()

                // Center: Compact playback controls
                HStack(spacing: 12) {
                    Button { seekToIndex(screenshots.count - 1) } label: {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)

                    Button { previousFrame() } label: {
                        Image(systemName: "backward.frame.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(OmiColors.purplePrimary)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button { nextFrame() } label: {
                        Image(systemName: "forward.frame.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)

                    Button { seekToIndex(0) } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Right: Position and timestamp
                if currentIndex < screenshots.count {
                    let screenshot = screenshots[currentIndex]
                    HStack(spacing: 8) {
                        Text("\(currentIndex + 1)/\(screenshots.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                        Text(screenshot.formattedDate)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(width: 160, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Search Result Indices

    private var searchResultIndices: [Int] {
        guard viewModel.activeSearchQuery != nil else { return [] }
        // All current screenshots are search results when searching
        return Array(0..<min(activeScreenshots.count, 100))
    }

    // MARK: - Playback

    private func loadCurrentFrame() async {
        let screenshots = activeScreenshots
        guard currentIndex < screenshots.count else { return }

        isLoadingFrame = true

        // Try to load current frame
        if let image = await tryLoadFrame(at: currentIndex) {
            currentImage = image
            viewModel.selectScreenshot(screenshots[currentIndex])
            isLoadingFrame = false
            return
        }

        // Current frame failed - search for first valid frame
        for offset in 1..<screenshots.count {
            // Try forward
            let forwardIndex = currentIndex + offset
            if forwardIndex < screenshots.count {
                if let image = await tryLoadFrame(at: forwardIndex) {
                    currentIndex = forwardIndex
                    currentImage = image
                    viewModel.selectScreenshot(screenshots[forwardIndex])
                    isLoadingFrame = false
                    log("RewindPage: Skipped to valid frame at index \(forwardIndex), imageSize=\(image.size), screenshotsCount=\(screenshots.count)")
                    return
                }
            }

            // Try backward
            let backwardIndex = currentIndex - offset
            if backwardIndex >= 0 {
                if let image = await tryLoadFrame(at: backwardIndex) {
                    currentIndex = backwardIndex
                    currentImage = image
                    viewModel.selectScreenshot(screenshots[backwardIndex])
                    isLoadingFrame = false
                    log("RewindPage: Skipped to valid frame at index \(backwardIndex)")
                    return
                }
            }
        }

        // No valid frames found
        currentImage = nil
        isLoadingFrame = false
        logError("RewindPage: No valid frames found")
    }

    /// Try to load a frame at a specific index, returns nil if failed
    private func tryLoadFrame(at index: Int) async -> NSImage? {
        let screenshots = activeScreenshots
        guard index >= 0 && index < screenshots.count else { return nil }
        let screenshot = screenshots[index]

        do {
            let image = try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
            // Validate image dimensions
            if image.size.width <= 0 || image.size.height <= 0 {
                logError("RewindPage: Loaded invalid image at index \(index) - size=\(image.size)")
                return nil
            }
            return image
        } catch {
            // Only log first few failures to avoid spam
            if index < 3 {
                logError("RewindPage: Failed to load frame at index \(index): \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func seekToIndex(_ index: Int) {
        let screenshots = activeScreenshots
        let newIndex = max(0, min(index, screenshots.count - 1))
        guard newIndex != currentIndex else { return }

        currentIndex = newIndex
        Task { await loadCurrentFrame() }
    }

    private func nextFrame() {
        seekToIndex(currentIndex - 1) // Screenshots are newest first
    }

    private func previousFrame() {
        seekToIndex(currentIndex + 1)
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        guard !isPlaying, !viewModel.screenshots.isEmpty else { return }
        isPlaying = true

        let interval = 1.0 / playbackSpeed
        playbackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [self] _ in
            Task { @MainActor in
                if currentIndex > 0 {
                    nextFrame()
                } else {
                    stopPlayback()
                }
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func restartPlayback() {
        stopPlayback()
        startPlayback()
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(OmiColors.purplePrimary.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 36))
                    .foregroundColor(OmiColors.purplePrimary.opacity(0.6))
            }

            Text("No Screenshots Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            Text("Screenshots will appear here as you use your Mac.\nRewind captures your screen every second.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Tip: Use search to find anything you've seen on screen")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
            .padding(.top, 8)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
                .tint(.white)

            Text("Loading screenshots...")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(OmiColors.error.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 36))
                    .foregroundColor(OmiColors.error)
            }

            Text("Failed to Load Screenshots")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))

            Button {
                Task { await viewModel.loadInitialData() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(OmiColors.purplePrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Search Result List Item (Google-style)

struct SearchResultListItem: View {
    let screenshot: Screenshot
    let index: Int
    let totalCount: Int
    let searchQuery: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                // Left side: Text content
                VStack(alignment: .leading, spacing: 6) {
                    // App name and window title (like URL in Google)
                    HStack(spacing: 6) {
                        AppIconView(appName: screenshot.appName, size: 16)
                        Text(screenshot.appName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.purplePrimary)
                        if let windowTitle = screenshot.windowTitle, !windowTitle.isEmpty {
                            Text("›")
                                .foregroundColor(.white.opacity(0.3))
                            Text(windowTitle)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    // Timestamp (like page title in Google)
                    Text(screenshot.formattedDate)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)

                    // Context snippet with highlighted search term
                    if let snippet = screenshot.contextSnippet(for: searchQuery) {
                        highlightedSnippet(snippet)
                    }

                    // Result number
                    Text("Result \(index + 1) of \(totalCount)")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.top, 2)
                }

                Spacer()

                // Right side: Small thumbnail
                Group {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 80)
                            .cornerRadius(6)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 120, height: 80)
                            .cornerRadius(6)
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.6)
                                    .tint(.white.opacity(0.5))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? OmiColors.purplePrimary.opacity(0.15) :
                          (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? OmiColors.purplePrimary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .task {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private func highlightedSnippet(_ snippet: String) -> some View {
        let lowercasedQuery = searchQuery.lowercased()
        let lowercasedSnippet = snippet.lowercased()

        if let range = lowercasedSnippet.range(of: lowercasedQuery) {
            // Use lowercasedSnippet for distance calculation to avoid String.Index incompatibility
            let beforeIndex = lowercasedSnippet.distance(from: lowercasedSnippet.startIndex, to: range.lowerBound)
            let afterIndex = lowercasedSnippet.distance(from: lowercasedSnippet.startIndex, to: range.upperBound)

            // Bounds check before creating indices
            if beforeIndex <= snippet.count, afterIndex <= snippet.count, beforeIndex <= afterIndex {
                let before = String(snippet.prefix(beforeIndex))
                let match = String(snippet[snippet.index(snippet.startIndex, offsetBy: beforeIndex)..<snippet.index(snippet.startIndex, offsetBy: afterIndex)])
                let after = String(snippet.suffix(from: snippet.index(snippet.startIndex, offsetBy: afterIndex)))

                (Text(before).foregroundColor(.white.opacity(0.6)) +
                 Text(match).foregroundColor(.white).bold() +
                 Text(after).foregroundColor(.white.opacity(0.6)))
                    .font(.system(size: 12))
                    .lineLimit(3)
            } else {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(3)
            }
        } else {
            Text(snippet)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(3)
        }
    }

    private func loadThumbnail() async {
        do {
            let image = try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
            await MainActor.run {
                thumbnail = image
            }
        } catch {
            // Thumbnail load failed, keep placeholder
        }
    }
}

// MARK: - Search Result Group Item (Grouped results)

struct SearchResultGroupItem: View {
    let group: SearchResultGroup
    let index: Int
    let totalGroups: Int
    let totalScreenshots: Int
    let searchQuery: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 16) {
                // Left side: Text content
                VStack(alignment: .leading, spacing: 6) {
                    // App name and window title
                    HStack(spacing: 6) {
                        AppIconView(appName: group.appName, size: 16)
                        Text(group.appName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.purplePrimary)
                        if let windowTitle = group.windowTitle, !windowTitle.isEmpty {
                            Text("›")
                                .foregroundColor(.white.opacity(0.3))
                            Text(windowTitle)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                    }

                    // Time range
                    Text(group.formattedTimeRange)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)

                    // Context snippet from representative screenshot
                    if let snippet = group.representativeScreenshot.contextSnippet(for: searchQuery) {
                        highlightedSnippet(snippet)
                    }

                    // Group info: count and position
                    HStack(spacing: 8) {
                        if group.count > 1 {
                            HStack(spacing: 4) {
                                Image(systemName: "square.stack")
                                    .font(.system(size: 9))
                                Text("\(group.count) screenshots")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.purplePrimary.opacity(0.8))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(OmiColors.purplePrimary.opacity(0.15))
                            .cornerRadius(4)
                        }

                        Text("Group \(index + 1) of \(totalGroups)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .padding(.top, 2)
                }

                Spacer()

                // Right side: Small thumbnail
                Group {
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 120, height: 80)
                            .cornerRadius(6)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 120, height: 80)
                            .cornerRadius(6)
                            .overlay(
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.6)
                                    .tint(.white.opacity(0.5))
                            )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? OmiColors.purplePrimary.opacity(0.15) :
                          (isHovered ? Color.white.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? OmiColors.purplePrimary.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .task {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private func highlightedSnippet(_ snippet: String) -> some View {
        let lowercasedQuery = searchQuery.lowercased()
        let lowercasedSnippet = snippet.lowercased()

        if let range = lowercasedSnippet.range(of: lowercasedQuery) {
            // Use lowercasedSnippet for distance calculation to avoid String.Index incompatibility
            let beforeIndex = lowercasedSnippet.distance(from: lowercasedSnippet.startIndex, to: range.lowerBound)
            let afterIndex = lowercasedSnippet.distance(from: lowercasedSnippet.startIndex, to: range.upperBound)

            // Bounds check before creating indices
            if beforeIndex <= snippet.count, afterIndex <= snippet.count, beforeIndex <= afterIndex {
                let before = String(snippet.prefix(beforeIndex))
                let match = String(snippet[snippet.index(snippet.startIndex, offsetBy: beforeIndex)..<snippet.index(snippet.startIndex, offsetBy: afterIndex)])
                let after = String(snippet.suffix(from: snippet.index(snippet.startIndex, offsetBy: afterIndex)))

                (Text(before).foregroundColor(.white.opacity(0.6)) +
                 Text(match).foregroundColor(.white).bold() +
                 Text(after).foregroundColor(.white.opacity(0.6)))
                    .font(.system(size: 12))
                    .lineLimit(3)
            } else {
                Text(snippet)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(3)
            }
        } else {
            Text(snippet)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(3)
        }
    }

    private func loadThumbnail() async {
        do {
            let image = try await RewindStorage.shared.loadScreenshotImage(for: group.representativeScreenshot)
            await MainActor.run {
                thumbnail = image
            }
        } catch {
            // Thumbnail load failed, keep placeholder
        }
    }
}

// MARK: - Search Result Row (Legacy)

struct SearchResultRow: View {
    let screenshot: Screenshot
    let searchQuery: String?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // App icon
                AppIconView(appName: screenshot.appName, size: 24)

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(screenshot.appName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)

                        if let windowTitle = screenshot.windowTitle, !windowTitle.isEmpty {
                            Text("— \(windowTitle)")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }

                    // Context snippet if searching
                    if let query = searchQuery,
                       let snippet = screenshot.contextSnippet(for: query) {
                        Text(snippet)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }

                Spacer()

                // Timestamp
                Text(screenshot.formattedDate)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.purplePrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? OmiColors.purplePrimary.opacity(0.2) :
                          (isHovered ? Color.white.opacity(0.1) : Color.white.opacity(0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? OmiColors.purplePrimary.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Scroll Wheel Capture View

/// NSViewRepresentable that captures scroll wheel events and forwards them to a handler
struct ScrollWheelCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> PageScrollWheelNSView {
        let view = PageScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: PageScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class PageScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // Use both deltaY (vertical scroll) and deltaX (horizontal scroll)
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        if delta != 0 {
            onScroll?(delta)
        }
    }
}

#Preview {
    RewindPage()
        .frame(width: 1000, height: 700)
}
