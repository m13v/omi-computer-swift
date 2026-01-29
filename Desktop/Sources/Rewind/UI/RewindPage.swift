import SwiftUI

/// Main Rewind page with search, timeline, and screenshot preview
struct RewindPage: View {
    @StateObject private var viewModel = RewindViewModel()
    @ObservedObject private var settings = RewindSettings.shared

    @State private var showingPreview = false

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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rewind")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

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
                // Preview mode
                ScreenshotPreviewView(
                    screenshot: selected,
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

                // Timeline at bottom
                RewindTimelineView(
                    screenshots: viewModel.screenshots,
                    selectedScreenshot: $viewModel.selectedScreenshot,
                    onSelect: { screenshot in
                        viewModel.selectScreenshot(screenshot)
                    }
                )
            } else {
                // Grid mode
                ScreenshotGridView(
                    screenshots: viewModel.screenshots,
                    selectedScreenshot: viewModel.selectedScreenshot,
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
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

            Text("No Screenshots Yet")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(OmiColors.textPrimary)

            Text("Screenshots will appear here as you use your Mac.\nRewind captures your screen every second.")
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var disabledState: some View {
        VStack(spacing: 16) {
            Image(systemName: "pause.circle")
                .font(.system(size: 48))
                .foregroundColor(OmiColors.textTertiary)

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
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(OmiColors.error)

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
        .frame(width: 800, height: 600)
        .background(OmiColors.backgroundPrimary)
}
