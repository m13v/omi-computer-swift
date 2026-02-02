import SwiftUI

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
    @FocusState private var isSearchFocused: Bool

    enum SearchViewMode {
        case results  // Full-screen search results
        case timeline // Timeline with search highlights
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            if viewModel.isLoading && viewModel.screenshots.isEmpty && viewModel.activeSearchQuery == nil {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.activeSearchQuery != nil || !viewModel.searchQuery.isEmpty {
                // Search is active - always show search UI even with 0 results
                searchContent
            } else if viewModel.screenshots.isEmpty {
                emptyState
            } else {
                // Normal timeline view
                timelineContent
            }
        }
        .task {
            await viewModel.loadInitialData()
        }
        .onChange(of: viewModel.screenshots) { _, screenshots in
            // Reset to first frame when screenshots change
            if !screenshots.isEmpty && currentIndex >= screenshots.count {
                currentIndex = 0
            }
            // Load frame for current position
            Task { await loadCurrentFrame() }
        }
        .onChange(of: viewModel.activeSearchQuery) { oldQuery, newQuery in
            // When search becomes active, default to results view
            if oldQuery == nil && newQuery != nil {
                searchViewMode = .results
            }
            // When search is cleared, reset view mode
            if newQuery == nil {
                searchViewMode = nil
            }
        }
        .onChange(of: viewModel.searchQuery) { _, newQuery in
            // Restore focus when typing (view may have switched between timelineContent and searchContent)
            if !newQuery.isEmpty && !isSearchFocused {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    isSearchFocused = true
                }
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
            // Up/down navigate search results
            if searchViewMode == .results && currentIndex < viewModel.screenshots.count - 1 {
                currentIndex += 1
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if searchViewMode == .results && currentIndex > 0 {
                currentIndex -= 1
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
    }

    // MARK: - Search Content (mode picker or full view)

    private var searchContent: some View {
        VStack(spacing: 0) {
            // Search header with editable field and view toggles
            searchHeader

            if viewModel.screenshots.isEmpty {
                // No results found
                noSearchResultsView
            } else if searchViewMode == .timeline {
                // Timeline view with search highlights
                timelineWithSearch
            } else {
                // Default to results list view
                fullScreenResultsView
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

    // MARK: - Search Header

    private var searchHeader: some View {
        HStack(spacing: 12) {
            // Back button - returns to results view or mode picker
            if searchViewMode == .timeline {
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
            }

            // Editable search field with results count
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
                } else {
                    // Results count
                    Text("\(viewModel.screenshots.count) results")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
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

            Spacer()

            // View mode toggle - always show when search is active
            HStack(spacing: 2) {
                Button {
                    searchViewMode = .results
                    if searchViewMode != .results && !viewModel.screenshots.isEmpty {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.8))
    }

    // MARK: - Full Screen Results View (Google-style vertical list)

    private var fullScreenResultsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(viewModel.screenshots.enumerated()), id: \.element.id) { index, screenshot in
                        SearchResultListItem(
                            screenshot: screenshot,
                            index: index,
                            totalCount: viewModel.screenshots.count,
                            searchQuery: viewModel.activeSearchQuery ?? "",
                            isSelected: index == currentIndex,
                            onTap: {
                                currentIndex = index
                                searchViewMode = .timeline
                                Task { await loadCurrentFrame() }
                            }
                        )
                        .id(index)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: currentIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
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

    // MARK: - Timeline Content (normal mode)

    private var timelineContent: some View {
        VStack(spacing: 0) {
            // Top bar with search
            topBar

            // Main frame display
            Spacer()
            frameDisplay
            Spacer()

            // Timeline and controls at bottom
            bottomControls
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 16) {
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

            // Search bar
            searchBar

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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.9), .black.opacity(0.6), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .offset(y: 20)
        )
    }

    // MARK: - Search Bar

    private var searchBar: some View {
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
            } else if let image = currentImage {
                // Calculate size to fill container while maintaining aspect ratio
                let imageAspect = image.size.width / image.size.height
                let containerAspect = geometry.size.width / geometry.size.height

                let displaySize: CGSize = {
                    if imageAspect > containerAspect {
                        // Wide image - fill width
                        let width = geometry.size.width
                        let height = width / imageAspect
                        return CGSize(width: width, height: height)
                    } else {
                        // Tall image - fill height
                        let height = geometry.size.height
                        let width = height * imageAspect
                        return CGSize(width: width, height: height)
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
                       currentIndex < viewModel.screenshots.count {
                        SearchHighlightOverlay(
                            screenshot: viewModel.screenshots[currentIndex],
                            query: query,
                            imageSize: image.size,
                            containerSize: displaySize
                        )
                        .frame(width: displaySize.width, height: displaySize.height)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
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
        VStack(spacing: 8) {
            // Timeline bar
            InteractiveTimelineBar(
                screenshots: viewModel.screenshots,
                currentIndex: currentIndex,
                searchResultIndices: viewModel.activeSearchQuery != nil ? Set(searchResultIndices) : nil,
                onSelect: { index in
                    seekToIndex(index)
                }
            )

            // Single compact control bar: app info | playback | position/time
            HStack(spacing: 16) {
                // Left: App icon and name
                if currentIndex < viewModel.screenshots.count {
                    let screenshot = viewModel.screenshots[currentIndex]
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
                    Button { seekToIndex(viewModel.screenshots.count - 1) } label: {
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
                if currentIndex < viewModel.screenshots.count {
                    let screenshot = viewModel.screenshots[currentIndex]
                    HStack(spacing: 8) {
                        Text("\(currentIndex + 1)/\(viewModel.screenshots.count)")
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
        return Array(0..<min(viewModel.screenshots.count, 100))
    }

    // MARK: - Playback

    private func loadCurrentFrame() async {
        guard currentIndex < viewModel.screenshots.count else { return }

        isLoadingFrame = true

        // Try to load current frame
        if let image = await tryLoadFrame(at: currentIndex) {
            currentImage = image
            viewModel.selectScreenshot(viewModel.screenshots[currentIndex])
            isLoadingFrame = false
            return
        }

        // Current frame failed - search for first valid frame
        for offset in 1..<viewModel.screenshots.count {
            // Try forward
            let forwardIndex = currentIndex + offset
            if forwardIndex < viewModel.screenshots.count {
                if let image = await tryLoadFrame(at: forwardIndex) {
                    currentIndex = forwardIndex
                    currentImage = image
                    viewModel.selectScreenshot(viewModel.screenshots[forwardIndex])
                    isLoadingFrame = false
                    log("RewindPage: Skipped to valid frame at index \(forwardIndex)")
                    return
                }
            }

            // Try backward
            let backwardIndex = currentIndex - offset
            if backwardIndex >= 0 {
                if let image = await tryLoadFrame(at: backwardIndex) {
                    currentIndex = backwardIndex
                    currentImage = image
                    viewModel.selectScreenshot(viewModel.screenshots[backwardIndex])
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
        guard index >= 0 && index < viewModel.screenshots.count else { return nil }
        let screenshot = viewModel.screenshots[index]

        do {
            return try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
        } catch {
            return nil
        }
    }

    private func seekToIndex(_ index: Int) {
        let newIndex = max(0, min(index, viewModel.screenshots.count - 1))
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
            let beforeIndex = snippet.distance(from: snippet.startIndex, to: range.lowerBound)
            let afterIndex = snippet.distance(from: snippet.startIndex, to: range.upperBound)

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

#Preview {
    RewindPage()
        .frame(width: 1000, height: 700)
}
