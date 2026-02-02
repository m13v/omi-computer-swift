import SwiftUI

/// Main Rewind page - Timeline-first view with integrated search
/// The timeline is the primary interface, with search results highlighted inline
struct RewindPage: View {
    @StateObject private var viewModel = RewindViewModel()
    @ObservedObject private var settings = RewindSettings.shared

    @State private var currentIndex: Int = 0
    @State private var currentImage: NSImage?
    @State private var isLoadingFrame = false
    @State private var isPlaying = false
    @State private var playbackSpeed: Double = 1.0
    @State private var playbackTimer: Timer?

    @State private var showSearchResults = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            // Background
            Color.black.ignoresSafeArea()

            if !settings.isEnabled {
                disabledState
            } else if viewModel.isLoading && viewModel.screenshots.isEmpty {
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

            // Toggle
            Toggle(isOn: $settings.isEnabled) {
                Text(settings.isEnabled ? "On" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(settings.isEnabled ? OmiColors.success : .white.opacity(0.5))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(OmiColors.purplePrimary)

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
            // Results header
            HStack {
                if let query = viewModel.activeSearchQuery {
                    Text("Results for \"\(query)\"")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))

                    Text("• \(viewModel.screenshots.count) matches")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }

                Spacer()

                // App filter in results
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

                Button {
                    showSearchResults = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            // Horizontal scrolling results
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(viewModel.screenshots.prefix(20).enumerated()), id: \.element.id) { index, screenshot in
                        SearchResultCard(
                            screenshot: screenshot,
                            searchQuery: viewModel.activeSearchQuery,
                            isSelected: currentIndex < viewModel.screenshots.count &&
                                       viewModel.screenshots[currentIndex].id == screenshot.id
                        ) {
                            // Navigate to this result
                            if let idx = viewModel.screenshots.firstIndex(where: { $0.id == screenshot.id }) {
                                seekToIndex(idx)
                            }
                            showSearchResults = false
                        }
                    }

                    if viewModel.screenshots.count > 20 {
                        VStack {
                            Text("+\(viewModel.screenshots.count - 20)")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.7))
                            Text("more")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .frame(width: 80, height: 60)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .background(Color.black.opacity(0.8))
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
            // App activity visualization with search markers
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))

                    // App segments
                    HStack(spacing: 1) {
                        ForEach(Array(appSegments.enumerated()), id: \.offset) { index, segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: max(2, geometry.size.width * segment.widthRatio))
                                .opacity(isInCurrentSegment(index) ? 1.0 : 0.5)
                        }
                    }

                    // Search result markers (yellow dots)
                    if viewModel.activeSearchQuery != nil {
                        ForEach(Array(searchResultIndices.enumerated()), id: \.offset) { _, idx in
                            let position = positionForIndex(idx, width: geometry.size.width)
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 6, height: 6)
                                .position(x: position, y: 4)
                        }
                    }
                }
            }
            .frame(height: 8)
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

    // MARK: - App Segments

    private struct AppSegment {
        let appName: String
        let color: Color
        let count: Int
        let widthRatio: CGFloat
    }

    private var appSegments: [AppSegment] {
        guard !viewModel.screenshots.isEmpty else { return [] }

        var segments: [AppSegment] = []
        var currentApp = viewModel.screenshots.first!.appName
        var currentCount = 0

        for screenshot in viewModel.screenshots {
            if screenshot.appName == currentApp {
                currentCount += 1
            } else {
                segments.append(AppSegment(
                    appName: currentApp,
                    color: colorForApp(currentApp),
                    count: currentCount,
                    widthRatio: CGFloat(currentCount) / CGFloat(viewModel.screenshots.count)
                ))
                currentApp = screenshot.appName
                currentCount = 1
            }
        }

        segments.append(AppSegment(
            appName: currentApp,
            color: colorForApp(currentApp),
            count: currentCount,
            widthRatio: CGFloat(currentCount) / CGFloat(viewModel.screenshots.count)
        ))

        return segments
    }

    private func isInCurrentSegment(_ segmentIndex: Int) -> Bool {
        var startIndex = 0
        for (index, segment) in appSegments.enumerated() {
            let endIndex = startIndex + segment.count - 1
            if index == segmentIndex {
                return currentIndex >= startIndex && currentIndex <= endIndex
            }
            startIndex = endIndex + 1
        }
        return false
    }

    private var searchResultIndices: [Int] {
        guard viewModel.activeSearchQuery != nil else { return [] }
        // All current screenshots are search results
        return Array(0..<min(viewModel.screenshots.count, 100))
    }

    private func positionForIndex(_ index: Int, width: CGFloat) -> CGFloat {
        guard viewModel.screenshots.count > 1 else { return width / 2 }
        let spacing = width / CGFloat(viewModel.screenshots.count - 1)
        return CGFloat(index) * spacing
    }

    private func colorForApp(_ appName: String) -> Color {
        let hash = abs(appName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.8)
    }

    // MARK: - Playback

    private func loadCurrentFrame() async {
        guard currentIndex < viewModel.screenshots.count else { return }

        isLoadingFrame = true
        let screenshot = viewModel.screenshots[currentIndex]

        do {
            let image = try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
            currentImage = image
            viewModel.selectScreenshot(screenshot)
        } catch {
            logError("RewindPage: Failed to load frame: \(error)")
            currentImage = nil
        }

        isLoadingFrame = false
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

    private var disabledState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "pause.circle")
                    .font(.system(size: 36))
                    .foregroundColor(.white.opacity(0.5))
            }

            Text("Rewind is Disabled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)

            Text("Enable Rewind to start capturing screenshots\nand building your searchable screen history.")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button {
                settings.isEnabled = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Enable Rewind")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(OmiColors.purplePrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
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

// MARK: - Search Result Card

struct SearchResultCard: View {
    let screenshot: Screenshot
    let searchQuery: String?
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Thumbnail
                ZStack {
                    if let image = thumbnail {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 140, height: 80)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 140, height: 80)
                        ProgressView()
                            .scaleEffect(0.6)
                            .tint(.white)
                    }
                }
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? OmiColors.purplePrimary : Color.clear, lineWidth: 2)
                )

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        AppIconView(appName: screenshot.appName, size: 12)
                        Text(screenshot.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }

                    Text(screenshot.formattedTime)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))

                    // Context snippet if searching
                    if let query = searchQuery,
                       let snippet = screenshot.contextSnippet(for: query) {
                        Text(snippet)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? Color.white.opacity(0.15) : Color.white.opacity(0.05))
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

    private func loadThumbnail() async {
        do {
            let fullImage = try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
            let size = NSSize(width: 280, height: 160)
            let newImage = NSImage(size: size)
            newImage.lockFocus()
            fullImage.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: fullImage.size),
                operation: .copy,
                fraction: 1.0
            )
            newImage.unlockFocus()
            thumbnail = newImage
        } catch {
            // Silent fail
        }
    }
}

#Preview {
    RewindPage()
        .frame(width: 1000, height: 700)
}
