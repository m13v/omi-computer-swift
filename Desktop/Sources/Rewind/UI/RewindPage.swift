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

    @State private var showSearchResults = false
    @State private var selectedSearchTab: SearchResultsTab? = nil
    @FocusState private var isSearchFocused: Bool

    enum SearchResultsTab {
        case list
    }

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            if viewModel.isLoading && viewModel.screenshots.isEmpty {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.screenshots.isEmpty {
                emptyState
            } else {
                // Main timeline view
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
        // Global keyboard handlers
        .onKeyPress(.escape) {
            if selectedSearchTab != nil {
                selectedSearchTab = nil
                return .handled
            }
            if showSearchResults {
                showSearchResults = false
                return .handled
            }
            if isSearchFocused {
                isSearchFocused = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            previousFrame()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            nextFrame()
            return .handled
        }
        .onKeyPress(.space) {
            togglePlayback()
            return .handled
        }
        .onKeyPress(.return) {
            if isSearchFocused && !viewModel.searchQuery.isEmpty {
                showSearchResults = true
                isSearchFocused = false
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Timeline Content

    private var timelineContent: some View {
        VStack(spacing: 0) {
            // Top bar with search
            topBar

            // Search results panel (slides down when searching)
            if showSearchResults && !viewModel.screenshots.isEmpty {
                searchResultsPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Main frame display
            Spacer()
            frameDisplay
            Spacer()

            // Timeline and controls at bottom
            bottomControls
        }
        .animation(.easeInOut(duration: 0.2), value: showSearchResults)
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
                .onSubmit {
                    if !viewModel.searchQuery.isEmpty {
                        showSearchResults = true
                    }
                }

            if viewModel.isSearching {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .tint(.white)
            }

            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.searchQuery = ""
                    showSearchResults = false
                    selectedSearchTab = nil
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

    // MARK: - Search Results Panel

    private var searchResultsPanel: some View {
        VStack(spacing: 0) {
            // Filmstrip view of search results (primary view)
            SearchResultsFilmstrip(
                screenshots: viewModel.screenshots,
                searchQuery: viewModel.activeSearchQuery,
                selectedIndex: $currentIndex,
                onSelect: { index in
                    seekToIndex(index)
                }
            )

            // App filter and close button
            HStack {
                // App filter
                if !viewModel.availableApps.isEmpty {
                    Menu {
                        Button {
                            Task { await viewModel.filterByApp(nil) }
                        } label: {
                            HStack {
                                Text("All Apps")
                                if viewModel.selectedApp == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        Divider()
                        ForEach(viewModel.availableApps, id: \.self) { app in
                            Button {
                                Task { await viewModel.filterByApp(app) }
                            } label: {
                                HStack {
                                    Text(app)
                                    if viewModel.selectedApp == app {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                            Text(viewModel.selectedApp ?? "All Apps")
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // View mode toggle (filmstrip vs list)
                HStack(spacing: 4) {
                    Button {
                        selectedSearchTab = nil // Filmstrip (default)
                    } label: {
                        Image(systemName: "rectangle.split.3x1")
                            .font(.system(size: 12))
                            .foregroundColor(selectedSearchTab == nil ? OmiColors.purplePrimary : .white.opacity(0.5))
                            .frame(width: 28, height: 24)
                            .background(selectedSearchTab == nil ? OmiColors.purplePrimary.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("Filmstrip view")

                    Button {
                        selectedSearchTab = .list
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 12))
                            .foregroundColor(selectedSearchTab == .list ? OmiColors.purplePrimary : .white.opacity(0.5))
                            .frame(width: 28, height: 24)
                            .background(selectedSearchTab == .list ? OmiColors.purplePrimary.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help("List view")
                }
                .padding(2)
                .background(Color.white.opacity(0.05))
                .cornerRadius(6)

                Button {
                    showSearchResults = false
                    selectedSearchTab = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6))

            // List view (optional, when tab selected)
            if selectedSearchTab == .list {
                searchResultsListView
            }
        }
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Search Results List View

    private var searchResultsListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.screenshots, id: \.id) { screenshot in
                    SearchResultRow(
                        screenshot: screenshot,
                        searchQuery: viewModel.activeSearchQuery,
                        isSelected: currentIndex < viewModel.screenshots.count &&
                                   viewModel.screenshots[currentIndex].id == screenshot.id
                    ) {
                        // Navigate to this result
                        if let idx = viewModel.screenshots.firstIndex(where: { $0.id == screenshot.id }) {
                            seekToIndex(idx)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 250)
    }

    // MARK: - Frame Display

    private var frameDisplay: some View {
        Group {
            if isLoadingFrame && currentImage == nil {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.5)
                    .tint(.white)
            } else if let image = currentImage {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.5), radius: 20)

                    // Search highlight overlays
                    if let query = viewModel.activeSearchQuery,
                       currentIndex < viewModel.screenshots.count {
                        GeometryReader { geometry in
                            SearchHighlightOverlay(
                                screenshot: viewModel.screenshots[currentIndex],
                                query: query,
                                imageSize: image.size,
                                containerSize: geometry.size
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No frame loaded")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Interactive timeline bar with hover effects
            InteractiveTimelineBar(
                screenshots: viewModel.screenshots,
                currentIndex: currentIndex,
                searchResultIndices: viewModel.activeSearchQuery != nil ? Set(searchResultIndices) : nil,
                onSelect: { index in
                    seekToIndex(index)
                }
            )
            .padding(.horizontal, 24)

            // Timeline slider
            Slider(
                value: Binding(
                    get: { Double(currentIndex) },
                    set: { seekToIndex(Int($0)) }
                ),
                in: 0...Double(max(0, viewModel.screenshots.count - 1)),
                step: 1
            )
            .tint(OmiColors.purplePrimary)
            .padding(.horizontal, 24)

            // Playback controls
            HStack(spacing: 24) {
                // Skip to start
                Button { seekToIndex(viewModel.screenshots.count - 1) } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.screenshots.isEmpty)
                .opacity(viewModel.screenshots.isEmpty ? 0.3 : 1)

                // Previous frame
                Button { previousFrame() } label: {
                    Image(systemName: "backward.frame.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex >= viewModel.screenshots.count - 1)
                .opacity(currentIndex >= viewModel.screenshots.count - 1 ? 0.3 : 1)

                // Play/Pause
                Button { togglePlayback() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(OmiColors.purplePrimary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.screenshots.isEmpty)

                // Next frame
                Button { nextFrame() } label: {
                    Image(systemName: "forward.frame.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex == 0)
                .opacity(currentIndex == 0 ? 0.3 : 1)

                // Skip to end
                Button { seekToIndex(0) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.screenshots.isEmpty)
                .opacity(viewModel.screenshots.isEmpty ? 0.3 : 1)
            }

            // Frame info
            frameInfo
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 200)
            .offset(y: -50)
        )
    }

    // MARK: - Frame Info

    private var frameInfo: some View {
        HStack {
            if currentIndex < viewModel.screenshots.count {
                let screenshot = viewModel.screenshots[currentIndex]

                // App icon and name
                HStack(spacing: 8) {
                    AppIconView(appName: screenshot.appName, size: 20)
                    Text(screenshot.appName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }

                Spacer()

                // Position counter
                Text("\(currentIndex + 1) / \(viewModel.screenshots.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                // Timestamp
                Text(screenshot.formattedDate)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
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

// MARK: - Search Result Row

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
