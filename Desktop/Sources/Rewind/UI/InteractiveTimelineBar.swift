import SwiftUI
import AppKit

/// Compact timeline bar with frame bars and mouse scroll navigation
struct InteractiveTimelineBar: View {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    let onSelect: (Int) -> Void

    @State private var hoveredIndex: Int? = nil

    // Bar dimensions
    private let frameWidth: CGFloat = 4
    private let frameSpacing: CGFloat = 1
    private let barHeight: CGFloat = 32

    // Visible window for performance
    private let visibleCount = 150

    var body: some View {
        VStack(spacing: 4) {
            // Timeline using NSViewRepresentable for proper scroll handling
            TimelineScrollView(
                screenshots: screenshots,
                currentIndex: currentIndex,
                searchResultIndices: searchResultIndices,
                hoveredIndex: $hoveredIndex,
                frameWidth: frameWidth,
                frameSpacing: frameSpacing,
                barHeight: barHeight,
                visibleCount: visibleCount,
                onSelect: onSelect
            )
            .frame(height: barHeight + 40) // Space for tooltip

            // Compact legend
            HStack(spacing: 16) {
                // Current indicator
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                    Text("current")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.4))
                }

                if searchResultIndices != nil && !(searchResultIndices?.isEmpty ?? true) {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.yellow.opacity(0.8))
                            .frame(width: 8, height: 8)
                        Text("match")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }

                Spacer()

                Text("scroll to navigate")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - NSView-based Timeline for proper scroll handling

struct TimelineScrollView: NSViewRepresentable {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    @Binding var hoveredIndex: Int?
    let frameWidth: CGFloat
    let frameSpacing: CGFloat
    let barHeight: CGFloat
    let visibleCount: Int
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView()
        view.onSelect = onSelect
        view.onHover = { index in
            DispatchQueue.main.async {
                hoveredIndex = index
            }
        }
        return view
    }

    func updateNSView(_ nsView: TimelineNSView, context: Context) {
        nsView.screenshots = screenshots
        nsView.currentIndex = currentIndex
        nsView.searchResultIndices = searchResultIndices
        nsView.hoveredIndex = hoveredIndex
        nsView.frameWidth = frameWidth
        nsView.frameSpacing = frameSpacing
        nsView.barHeight = barHeight
        nsView.visibleCount = visibleCount
        nsView.onSelect = onSelect
        nsView.needsDisplay = true
    }
}

class TimelineNSView: NSView {
    var screenshots: [Screenshot] = []
    var currentIndex: Int = 0
    var searchResultIndices: Set<Int>?
    var hoveredIndex: Int?
    var frameWidth: CGFloat = 4
    var frameSpacing: CGFloat = 1
    var barHeight: CGFloat = 32
    var visibleCount: Int = 150
    var onSelect: ((Int) -> Void)?
    var onHover: ((Int?) -> Void)?

    private var trackingArea: NSTrackingArea?
    private var tooltipWindow: NSWindow?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTrackingArea()
    }

    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        setupTrackingArea()
    }

    // Handle scroll wheel - this is the key fix
    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        let framesToSkip = Int(delta * 2)

        if framesToSkip != 0 {
            let newIndex = max(0, min(screenshots.count - 1, currentIndex - framesToSkip))
            if newIndex != currentIndex {
                onSelect?(newIndex)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let index = indexAtPoint(location) {
            onSelect?(index)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let index = indexAtPoint(location)
        onHover?(index)

        if let idx = index, idx < screenshots.count {
            showTooltip(for: screenshots[idx], at: location)
        } else {
            hideTooltip()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
        hideTooltip()
        needsDisplay = true
    }

    private func indexAtPoint(_ point: CGPoint) -> Int? {
        let centerX = bounds.width / 2
        let totalWidth = frameWidth + frameSpacing

        // Calculate visible range
        let halfWindow = visibleCount / 2
        let startIndex = max(0, currentIndex - halfWindow)
        let endIndex = min(screenshots.count, currentIndex + halfWindow)

        // Calculate offset from center
        let currentBarX = centerX - frameWidth / 2

        for i in startIndex..<endIndex {
            let offset = CGFloat(i - currentIndex)
            let barX = currentBarX + offset * totalWidth
            if point.x >= barX && point.x < barX + frameWidth {
                return i
            }
        }
        return nil
    }

    private func showTooltip(for screenshot: Screenshot, at point: CGPoint) {
        hideTooltip()

        let tooltipView = NSHostingView(rootView: TooltipView(screenshot: screenshot))
        tooltipView.frame.size = tooltipView.fittingSize

        let windowPoint = convert(point, to: nil)
        guard let screenPoint = window?.convertPoint(toScreen: windowPoint) else { return }

        let tooltipWindow = NSWindow(
            contentRect: NSRect(x: screenPoint.x - tooltipView.frame.width / 2,
                              y: screenPoint.y + 20,
                              width: tooltipView.frame.width,
                              height: tooltipView.frame.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        tooltipWindow.backgroundColor = .clear
        tooltipWindow.isOpaque = false
        tooltipWindow.level = .floating
        tooltipWindow.contentView = tooltipView
        tooltipWindow.orderFront(nil)
        self.tooltipWindow = tooltipWindow
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipWindow = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !screenshots.isEmpty else { return }

        let context = NSGraphicsContext.current?.cgContext
        context?.clear(bounds)

        let centerX = bounds.width / 2
        let totalWidth = frameWidth + frameSpacing
        let bottomY = bounds.height - 8 // Leave space at bottom

        // Calculate visible range
        let halfWindow = visibleCount / 2
        let startIndex = max(0, currentIndex - halfWindow)
        let endIndex = min(screenshots.count, currentIndex + halfWindow)

        for i in startIndex..<endIndex {
            let offset = CGFloat(i - currentIndex)
            let barX = centerX - frameWidth / 2 + offset * totalWidth

            let isCurrent = i == currentIndex
            let isHovered = i == hoveredIndex
            let isSearchResult = searchResultIndices?.contains(i) ?? false

            // Bar height
            let heightRatio: CGFloat = (isCurrent || isHovered) ? 1.0 : 0.5
            let barHeight = self.barHeight * heightRatio

            // Bar color
            let color: NSColor
            if isCurrent {
                color = .white
            } else if isSearchResult {
                color = NSColor.yellow.withAlphaComponent(0.8)
            } else {
                color = NSColor(white: 0.4, alpha: 1.0)
            }

            // Draw bar
            let barRect = NSRect(x: barX, y: bottomY - barHeight, width: frameWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            color.setFill()
            path.fill()

            // Glow for current
            if isCurrent {
                let glowColor = NSColor.white.withAlphaComponent(0.3)
                glowColor.setFill()
                let glowRect = barRect.insetBy(dx: -2, dy: -2)
                let glowPath = NSBezierPath(roundedRect: glowRect, xRadius: 3, yRadius: 3)
                glowPath.fill()

                // Redraw bar on top
                color.setFill()
                path.fill()
            }
        }
    }
}

// MARK: - Tooltip View

struct TooltipView: View {
    let screenshot: Screenshot

    var body: some View {
        HStack(spacing: 6) {
            AppIconView(appName: screenshot.appName, size: 14)
            Text(screenshot.appName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(screenshot.formattedTime)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        )
    }
}

#Preview {
    InteractiveTimelineBar(
        screenshots: [],
        currentIndex: 50,
        searchResultIndices: [10, 25, 40, 60, 80],
        onSelect: { _ in }
    )
    .frame(width: 800, height: 100)
    .background(Color.black)
}
