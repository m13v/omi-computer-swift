import SwiftUI
import AppKit

/// Thumbnail view for a single screenshot in the grid
struct ScreenshotThumbnailView: View {
    let screenshot: Screenshot
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var thumbnailImage: NSImage? = nil
    @State private var isHovered = false
    @State private var isLoading = true

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Thumbnail image
                ZStack {
                    if let image = thumbnailImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(height: 120)
                            .clipped()
                    } else if isLoading {
                        Rectangle()
                            .fill(OmiColors.backgroundTertiary)
                            .frame(height: 120)
                            .overlay {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.8)
                            }
                    } else {
                        Rectangle()
                            .fill(OmiColors.backgroundTertiary)
                            .frame(height: 120)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 24))
                                    .foregroundColor(OmiColors.textQuaternary)
                            }
                    }

                    // Hover overlay with delete button
                    if isHovered {
                        Color.black.opacity(0.3)

                        VStack {
                            HStack {
                                Spacer()
                                Button {
                                    onDelete()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Color.red.opacity(0.8))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }
                .frame(height: 120)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? OmiColors.purplePrimary : Color.clear, lineWidth: 2)
                )

                // Info section
                VStack(alignment: .leading, spacing: 4) {
                    // App name
                    HStack(spacing: 4) {
                        Image(systemName: "app.badge")
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textTertiary)

                        Text(screenshot.appName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(OmiColors.textSecondary)
                            .lineLimit(1)
                    }

                    // Time
                    Text(screenshot.formattedTime)
                        .font(.system(size: 10))
                        .foregroundColor(OmiColors.textTertiary)

                    // Window title (if available)
                    if let title = screenshot.windowTitle, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 10))
                            .foregroundColor(OmiColors.textQuaternary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(isSelected ? OmiColors.purplePrimary.opacity(0.1) : OmiColors.backgroundTertiary.opacity(0.5))
            .cornerRadius(10)
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
        isLoading = true
        do {
            let image = try await RewindStorage.shared.loadScreenshotImage(relativePath: screenshot.imagePath)
            // Create thumbnail
            let thumbnailSize = NSSize(width: 300, height: 200)
            thumbnailImage = resizeImage(image, to: thumbnailSize)
        } catch {
            logError("ScreenshotThumbnailView: Failed to load thumbnail: \(error)")
        }
        isLoading = false
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

/// Grid view showing multiple screenshot thumbnails
struct ScreenshotGridView: View {
    let screenshots: [Screenshot]
    let selectedScreenshot: Screenshot?
    let onSelect: (Screenshot) -> Void
    let onDelete: (Screenshot) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(screenshots) { screenshot in
                    ScreenshotThumbnailView(
                        screenshot: screenshot,
                        isSelected: selectedScreenshot?.id == screenshot.id,
                        onSelect: { onSelect(screenshot) },
                        onDelete: { onDelete(screenshot) }
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
}
