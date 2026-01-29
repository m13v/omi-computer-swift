import SwiftUI
import AppKit

/// Timeline scrubber view for navigating through screenshots
struct RewindTimelineView: View {
    let screenshots: [Screenshot]
    @Binding var selectedScreenshot: Screenshot?
    let onSelect: (Screenshot) -> Void

    @State private var hoveredIndex: Int? = nil

    private let thumbnailWidth: CGFloat = 80
    private let thumbnailHeight: CGFloat = 50

    var body: some View {
        VStack(spacing: 8) {
            // Timeline scrubber
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, screenshot in
                            timelineThumbnail(screenshot, index: index)
                                .id(screenshot.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onChange(of: selectedScreenshot) { _, newValue in
                    if let id = newValue?.id {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            .frame(height: thumbnailHeight + 24)
            .background(OmiColors.backgroundTertiary.opacity(0.5))

            // Time range label
            if !screenshots.isEmpty {
                HStack {
                    if let first = screenshots.last {
                        Text(first.formattedTime)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    if let selected = selectedScreenshot {
                        Text(selected.formattedDate)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)
                    }

                    Spacer()

                    if let last = screenshots.first {
                        Text(last.formattedTime)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func timelineThumbnail(_ screenshot: Screenshot, index: Int) -> some View {
        let isSelected = selectedScreenshot?.id == screenshot.id
        let isHovered = hoveredIndex == index

        return Button {
            onSelect(screenshot)
        } label: {
            TimelineThumbnailImage(
                screenshot: screenshot,
                width: thumbnailWidth,
                height: thumbnailHeight
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? OmiColors.purplePrimary : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredIndex = hovering ? index : nil
            }
        }
    }
}

/// Async-loading thumbnail for the timeline
struct TimelineThumbnailImage: View {
    let screenshot: Screenshot
    let width: CGFloat
    let height: CGFloat

    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .cornerRadius(4)
            } else {
                Rectangle()
                    .fill(OmiColors.backgroundQuaternary)
                    .frame(width: width, height: height)
                    .cornerRadius(4)
            }
        }
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            let fullImage = try await RewindStorage.shared.loadScreenshotImage(relativePath: screenshot.imagePath)
            // Create small thumbnail
            let thumbnailSize = NSSize(width: width * 2, height: height * 2)
            image = resizeImage(fullImage, to: thumbnailSize)
        } catch {
            // Silently fail - thumbnail will show placeholder
        }
    }

    private func resizeImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }
}

/// Full-size screenshot preview view
struct ScreenshotPreviewView: View {
    let screenshot: Screenshot
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @State private var fullImage: NSImage? = nil
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                // App info
                HStack(spacing: 8) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textTertiary)

                    Text(screenshot.appName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)

                    if let title = screenshot.windowTitle {
                        Text("•")
                            .foregroundColor(OmiColors.textTertiary)

                        Text(title)
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Time
                Text(screenshot.formattedDate)
                    .font(.system(size: 13))
                    .foregroundColor(OmiColors.textTertiary)

                // Close button
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(OmiColors.backgroundTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(OmiColors.backgroundSecondary.opacity(0.8))

            // Image
            ZStack {
                if let image = fullImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 48))
                        .foregroundColor(OmiColors.textQuaternary)
                }

                // Navigation arrows
                HStack {
                    navButton(systemName: "chevron.left", action: onPrevious)
                    Spacer()
                    navButton(systemName: "chevron.right", action: onNext)
                }
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.3))

            // OCR text preview (if available)
            if let ocrText = screenshot.ocrText, !ocrText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)

                        Text("Extracted Text")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)

                        Spacer()
                    }

                    ScrollView {
                        Text(ocrText)
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                .padding(12)
                .background(OmiColors.backgroundTertiary.opacity(0.8))
            }
        }
        .task {
            await loadFullImage()
        }
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func loadFullImage() async {
        isLoading = true
        do {
            fullImage = try await RewindStorage.shared.loadScreenshotImage(relativePath: screenshot.imagePath)
        } catch {
            logError("ScreenshotPreviewView: Failed to load image: \(error)")
        }
        isLoading = false
    }
}
