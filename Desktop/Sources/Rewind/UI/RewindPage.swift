import SwiftUI

/// Main Rewind page with search, timeline, and screenshot preview
struct RewindPage: View {
    @StateObject private var viewModel = RewindViewModel()
    @ObservedObject private var settings = RewindSettings.shared

    @State private var showingPreview = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            if !settings.isEnabled {
                disabledState
            } else if viewModel.isLoading && viewModel.screenshots.isEmpty {
                loadingView
            } else if let error = viewModel.errorMessage {
                errorView(error)
            } else if viewModel.screenshots.isEmpty {
                emptyState
            } else {
                // Main content
                mainContent
            }
        }
        .background(Color.clear)
        .task {
            await viewModel.loadInitialData()
        }
        // Global keyboard handler
        .onKeyPress(.escape) {
            if showingPreview {
                showingPreview = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.leftArrow) {
            if showingPreview {
                viewModel.selectPreviousScreenshot()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.rightArrow) {
            if showingPreview {
                viewModel.selectNextScreenshot()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.space) {
            if viewModel.selectedScreenshot != nil, !showingPreview {
                showingPreview = true
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20))
                        .foregroundColor(OmiColors.purplePrimary)

                    Text("Rewind")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(OmiColors.textPrimary)
                }

                if let stats = viewModel.stats {
                    Text("\(stats.total) screenshots • \(RewindStorage.formatBytes(stats.storageSize))")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                } else {
                    Text("Search your screen history")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }

            Spacer()

            // Keyboard shortcut hint
            HStack(spacing: 4) {
                Image(systemName: "command")
                    .font(.system(size: 10))
                Text("⇧")
                    .font(.system(size: 12))
                Text("R")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(OmiColors.textQuaternary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(4)

            // Toggle button
            Toggle(isOn: $settings.isEnabled) {
                Text(settings.isEnabled ? "Enabled" : "Disabled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(settings.isEnabled ? OmiColors.success : OmiColors.textTertiary)
            }
            .toggleStyle(.switch)
            .tint(OmiColors.purplePrimary)

            // Refresh button
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textTertiary)
                    .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                    .animation(viewModel.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: viewModel.isLoading)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Search bar
            RewindSearchBar(
                searchQuery: $viewModel.searchQuery,
                selectedApp: $viewModel.selectedApp,
                selectedDate: $viewModel.selectedDate,
                availableApps: viewModel.availableApps,
                isSearching: viewModel.isSearching,
                onAppFilterChanged: { app in
                    Task { await viewModel.filterByApp(app) }
                },
                onDateChanged: { date in
                    Task { await viewModel.filterByDate(date) }
                }
            )
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            // Split view: Grid or Preview
            if showingPreview, let selected = viewModel.selectedScreenshot {
                // Preview mode with search highlighting
                ScreenshotPreviewView(
                    screenshot: selected,
                    searchQuery: viewModel.activeSearchQuery,
                    onPrevious: {
                        viewModel.selectPreviousScreenshot()
                    },
                    onNext: {
                        viewModel.selectNextScreenshot()
                    },
                    onClose: {
                        showingPreview = false
                    }
                )

                // Timeline at bottom with scroll support
                RewindTimelineView(
                    screenshots: viewModel.screenshots,
                    selectedScreenshot: $viewModel.selectedScreenshot,
                    onSelect: { screenshot in
                        viewModel.selectScreenshot(screenshot)
                    }
                )
            } else {
                // Grid mode with search context
                ScreenshotGridView(
                    screenshots: viewModel.screenshots,
                    selectedScreenshot: viewModel.selectedScreenshot,
                    searchQuery: viewModel.activeSearchQuery,
                    onSelect: { screenshot in
                        viewModel.selectScreenshot(screenshot)
                        showingPreview = true
                    },
                    onDelete: { screenshot in
                        Task { await viewModel.deleteScreenshot(screenshot) }
                    }
                )
            }
        }
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
                .foregroundColor(OmiColors.textPrimary)

            Text("Screenshots will appear here as you use your Mac.\nRewind captures your screen every second.")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)

            // Quick tip
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Tip: Use search to find anything you've seen on screen")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(OmiColors.backgroundTertiary)
            .cornerRadius(8)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disabledState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(OmiColors.backgroundTertiary)
                    .frame(width: 80, height: 80)

                Image(systemName: "pause.circle")
                    .font(.system(size: 36))
                    .foregroundColor(OmiColors.textTertiary)
            }

            Text("Rewind is Disabled")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Enable Rewind to start capturing screenshots\nand building your searchable screen history.")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)

            Text("Loading screenshots...")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .foregroundColor(OmiColors.textPrimary)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    RewindPage()
        .frame(width: 900, height: 700)
        .background(OmiColors.backgroundPrimary)
}
