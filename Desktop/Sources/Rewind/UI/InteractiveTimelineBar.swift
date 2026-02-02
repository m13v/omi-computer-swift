import SwiftUI

/// Interactive timeline bar with hover effects - segments grow and lift when hovered (Screenpipe-style)
struct InteractiveTimelineBar: View {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    let onSelect: (Int) -> Void

    @State private var hoveredSegmentIndex: Int? = nil
    @State private var hoveredFrameIndex: Int? = nil
    @State private var hoverPosition: CGFloat = 0

    private let defaultHeight: CGFloat = 16
    private let hoveredHeight: CGFloat = 32
    private let liftAmount: CGFloat = 12  // How much segments lift on hover (like Screenpipe's y: -20)
    private let searchMarkerHeight: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let segments = computeSegments()

            ZStack(alignment: .bottom) {
                // Background track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: defaultHeight)

                // App segments with hover lift effect
                HStack(spacing: 1) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let isHovered = hoveredSegmentIndex == index
                        let isCurrent = isInCurrentSegment(index, segments: segments)

                        InteractiveSegment(
                            segment: segment,
                            isHovered: isHovered,
                            isCurrentSegment: isCurrent,
                            defaultHeight: defaultHeight,
                            hoveredHeight: hoveredHeight,
                            width: geometry.size.width * segment.widthRatio
                        ) {
                            let segmentStartIndex = segments[0..<index].reduce(0) { $0 + $1.count }
                            let middleIndex = segmentStartIndex + segment.count / 2
                            onSelect(middleIndex)
                        }
                        // Screenpipe-style lift effect on hover
                        .offset(y: isHovered ? -liftAmount : 0)
                        .scaleEffect(isHovered ? 1.15 : 1.0, anchor: .bottom)
                        .zIndex(isHovered ? 100 : (isCurrent ? 50 : Double(index)))
                        .onHover { hovering in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                hoveredSegmentIndex = hovering ? index : nil
                            }
                        }
                    }
                }
                .frame(height: hoveredHeight + liftAmount)
                .padding(.bottom, 4)

                // Hover tooltip showing app name and time
                if let hoveredIndex = hoveredSegmentIndex, hoveredIndex < segments.count {
                    let segment = segments[hoveredIndex]
                    TimelineTooltip(appName: segment.appName, color: segment.color)
                        .offset(y: -hoveredHeight - liftAmount - 40)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }

                // Search result markers (yellow dots with glow)
                if let searchIndices = searchResultIndices, !searchIndices.isEmpty {
                    ForEach(Array(searchIndices.prefix(50)), id: \.self) { idx in
                        let position = positionForIndex(idx, width: geometry.size.width)
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: searchMarkerHeight, height: searchMarkerHeight)
                            .shadow(color: Color.yellow.opacity(0.6), radius: 4)
                            .shadow(color: Color.yellow.opacity(0.3), radius: 8)
                            .position(x: position, y: 0)
                    }
                }

                // Current position indicator with glow (Screenpipe-style)
                let currentPosition = positionForIndex(currentIndex, width: geometry.size.width)
                ZStack {
                    // Outer glow
                    RoundedRectangle(cornerRadius: 3)
                        .fill(OmiColors.purplePrimary.opacity(0.3))
                        .frame(width: 10, height: hoveredHeight + 16)
                        .blur(radius: 4)

                    // Inner indicator
                    RoundedRectangle(cornerRadius: 2)
                        .fill(OmiColors.purplePrimary)
                        .frame(width: 4, height: hoveredHeight + 12)
                        .shadow(color: OmiColors.purplePrimary.opacity(0.8), radius: 6)
                        .shadow(color: OmiColors.purplePrimary.opacity(0.4), radius: 12)
                }
                .position(x: currentPosition, y: (hoveredHeight + liftAmount) / 2)
            }
            .frame(height: hoveredHeight + liftAmount + 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        hoverPosition = value.location.x
                        let index = indexForPosition(value.location.x, width: geometry.size.width)
                        onSelect(index)
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverPosition = location.x
                    let index = indexForPosition(location.x, width: geometry.size.width)
                    hoveredFrameIndex = index
                case .ended:
                    hoveredFrameIndex = nil
                }
            }
        }
        .frame(height: hoveredHeight + liftAmount + 20)
    }

    // MARK: - Segment Computation

    struct Segment {
        let appName: String
        let color: Color
        let count: Int
        let widthRatio: CGFloat
        let startIndex: Int
    }

    private func computeSegments() -> [Segment] {
        guard !screenshots.isEmpty else { return [] }

        var segments: [Segment] = []
        var currentApp = screenshots.first!.appName
        var currentCount = 0
        var startIndex = 0

        for (index, screenshot) in screenshots.enumerated() {
            if screenshot.appName == currentApp {
                currentCount += 1
            } else {
                segments.append(Segment(
                    appName: currentApp,
                    color: colorForApp(currentApp),
                    count: currentCount,
                    widthRatio: CGFloat(currentCount) / CGFloat(screenshots.count),
                    startIndex: startIndex
                ))
                currentApp = screenshot.appName
                startIndex = index
                currentCount = 1
            }
        }

        // Add final segment
        segments.append(Segment(
            appName: currentApp,
            color: colorForApp(currentApp),
            count: currentCount,
            widthRatio: CGFloat(currentCount) / CGFloat(screenshots.count),
            startIndex: startIndex
        ))

        return segments
    }

    private func isInCurrentSegment(_ segmentIndex: Int, segments: [Segment]) -> Bool {
        guard segmentIndex < segments.count else { return false }
        let segment = segments[segmentIndex]
        return currentIndex >= segment.startIndex && currentIndex < segment.startIndex + segment.count
    }

    private func positionForIndex(_ index: Int, width: CGFloat) -> CGFloat {
        guard screenshots.count > 1 else { return width / 2 }
        let spacing = width / CGFloat(screenshots.count - 1)
        return CGFloat(index) * spacing
    }

    private func indexForPosition(_ x: CGFloat, width: CGFloat) -> Int {
        guard screenshots.count > 1 else { return 0 }
        let spacing = width / CGFloat(screenshots.count - 1)
        let index = Int(x / spacing)
        return max(0, min(screenshots.count - 1, index))
    }

    private func colorForApp(_ appName: String) -> Color {
        let hash = abs(appName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.65, brightness: 0.85)
    }
}

// MARK: - Interactive Segment

/// Tooltip showing app name when hovering over timeline
struct TimelineTooltip: View {
    let appName: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(appName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        )
    }
}

struct InteractiveSegment: View {
    let segment: InteractiveTimelineBar.Segment
    typealias Segment = InteractiveTimelineBar.Segment
    let isHovered: Bool
    let isCurrentSegment: Bool
    let defaultHeight: CGFloat
    let hoveredHeight: CGFloat
    let width: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: isHovered ? 4 : 2)
                .fill(
                    isCurrentSegment ?
                    LinearGradient(
                        colors: [segment.color, segment.color.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    ) :
                    LinearGradient(
                        colors: [segment.color.opacity(isHovered ? 0.95 : 0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(
                    width: max(3, width),
                    height: isHovered ? hoveredHeight : defaultHeight
                )
                .overlay(
                    // Subtle inner highlight on hover
                    RoundedRectangle(cornerRadius: isHovered ? 4 : 2)
                        .stroke(Color.white.opacity(isHovered ? 0.3 : 0), lineWidth: 1)
                )
                .shadow(
                    color: isHovered ? segment.color.opacity(0.4) : .clear,
                    radius: isHovered ? 6 : 0
                )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isCurrentSegment)
    }
}


// MARK: - Mini Thumbnail Timeline (alternative style)

/// A timeline that shows mini thumbnails instead of colored bars
struct ThumbnailTimelineBar: View {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @State private var hoveredIndex: Int? = nil
    @State private var thumbnailCache: [Int64: NSImage] = [:]

    private let thumbnailSize: CGFloat = 40
    private let hoveredSize: CGFloat = 60
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let visibleCount = Int(geometry.size.width / (thumbnailSize + spacing))
            let step = max(1, screenshots.count / visibleCount)

            HStack(spacing: spacing) {
                ForEach(Array(stride(from: 0, to: screenshots.count, by: step).enumerated()), id: \.offset) { _, index in
                    let screenshot = screenshots[index]
                    let isHovered = hoveredIndex == index
                    let isCurrent = abs(currentIndex - index) < step

                    MiniThumbnail(
                        screenshot: screenshot,
                        thumbnail: screenshot.id.flatMap { thumbnailCache[$0] },
                        isHovered: isHovered,
                        isCurrent: isCurrent,
                        size: isHovered ? hoveredSize : thumbnailSize
                    ) {
                        onSelect(index)
                    }
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.1)) {
                            hoveredIndex = hovering ? index : nil
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: hoveredSize + 10)
    }
}

struct MiniThumbnail: View {
    let screenshot: Screenshot
    let thumbnail: NSImage?
    let isHovered: Bool
    let isCurrent: Bool
    let size: CGFloat
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Group {
                if let image = thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(colorForApp(screenshot.appName))
                }
            }
            .frame(width: size, height: size * 0.6)
            .clipped()
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isCurrent ? OmiColors.purplePrimary :
                        (isHovered ? Color.white.opacity(0.6) : Color.clear),
                        lineWidth: isCurrent ? 2 : 1
                    )
            )
            .shadow(
                color: isCurrent ? OmiColors.purplePrimary.opacity(0.4) : .clear,
                radius: 4
            )
            .scaleEffect(isHovered ? 1.1 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isCurrent)
    }

    private func colorForApp(_ appName: String) -> Color {
        let hash = abs(appName.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.7)
    }
}

#Preview {
    VStack(spacing: 40) {
        InteractiveTimelineBar(
            screenshots: [],
            currentIndex: 50,
            searchResultIndices: [10, 25, 40, 60, 80],
            onSelect: { _ in }
        )
        .padding()
        .background(Color.black)

        ThumbnailTimelineBar(
            screenshots: [],
            currentIndex: 5,
            onSelect: { _ in }
        )
        .padding()
        .background(Color.black)
    }
    .frame(width: 800, height: 300)
}
