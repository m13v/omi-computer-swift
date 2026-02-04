import SwiftUI
import AppKit

/// Full-width timeline bar with moving playhead (video player style)
struct InteractiveTimelineBar: View {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    let onSelect: (Int) -> Void

    @State private var hoveredIndex: Int? = nil

    private let barHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 4) {
            // Full-width timeline with moving playhead
            FullWidthTimelineView(
                screenshots: screenshots,
                currentIndex: currentIndex,
                searchResultIndices: searchResultIndices,
                hoveredIndex: $hoveredIndex,
                barHeight: barHeight,
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

// MARK: - Full Width Timeline with Moving Playhead

struct FullWidthTimelineView: NSViewRepresentable {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    @Binding var hoveredIndex: Int?
    let barHeight: CGFloat
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> FullWidthTimelineNSView {
        let view = FullWidthTimelineNSView()
        view.onSelect = onSelect
        view.onHover = { index in
            DispatchQueue.main.async {
                hoveredIndex = index
            }
        }
        return view
    }

    func updateNSView(_ nsView: FullWidthTimelineNSView, context: Context) {
        nsView.screenshots = screenshots
        nsView.currentIndex = currentIndex
        nsView.searchResultIndices = searchResultIndices
        nsView.hoveredIndex = hoveredIndex
        nsView.barHeight = barHeight
        nsView.onSelect = onSelect
        nsView.needsDisplay = true
    }
}

// MARK: - NSView Implementation

class FullWidthTimelineNSView: NSView {
    var screenshots: [Screenshot] = []
    var currentIndex: Int = 0
    var searchResultIndices: Set<Int>?
    var hoveredIndex: Int?
    var barHeight: CGFloat = 32
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

    // Handle scroll wheel - move playhead
    override func scrollWheel(with event: NSEvent) {
        guard !screenshots.isEmpty else { return }

        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        let sensitivity: CGFloat = 3.0 // Frames per scroll unit
        let framesToMove = Int(-delta * sensitivity)

        if framesToMove != 0 {
            let newIndex = max(0, min(screenshots.count - 1, currentIndex + framesToMove))
            if newIndex != currentIndex {
                onSelect?(newIndex)
            }
        }
    }

    // Handle click - jump to position
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let index = indexAtPoint(location) {
            onSelect?(index)
        }
    }

    // Handle hover - show tooltip
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let index = indexAtPoint(location)
        hoveredIndex = index
        onHover?(index)

        if let idx = index, idx < screenshots.count {
            showTooltip(for: screenshots[idx], at: location)
        } else {
            hideTooltip()
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        onHover?(nil)
        hideTooltip()
        needsDisplay = true
    }

    // Convert x position to frame index
    private func indexAtPoint(_ point: CGPoint) -> Int? {
        let timelineRect = timelineRect()
        guard timelineRect.contains(point), !screenshots.isEmpty else { return nil }

        let relativeX = point.x - timelineRect.minX
        let ratio = relativeX / timelineRect.width
        let index = Int(ratio * CGFloat(screenshots.count))
        return max(0, min(screenshots.count - 1, index))
    }

    // Get the timeline drawing area
    private func timelineRect() -> NSRect {
        let padding: CGFloat = 20
        let bottomY = bounds.height - barHeight - 8
        return NSRect(x: padding, y: bottomY, width: bounds.width - padding * 2, height: barHeight)
    }

    // Convert frame index to x position
    private func xPositionForIndex(_ index: Int) -> CGFloat {
        let rect = timelineRect()
        guard screenshots.count > 1 else { return rect.midX }
        let ratio = CGFloat(index) / CGFloat(screenshots.count - 1)
        return rect.minX + ratio * rect.width
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

        let rect = timelineRect()

        // Draw background track
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor(white: 0.2, alpha: 1.0).setFill()
        trackPath.fill()

        // Draw frame density visualization (activity blocks)
        drawActivityBlocks(in: rect)

        // Draw search result markers
        if let searchIndices = searchResultIndices, !searchIndices.isEmpty {
            drawSearchMarkers(indices: searchIndices, in: rect)
        }

        // Draw playhead (current position)
        drawPlayhead(in: rect)

        // Draw hover indicator
        if let hovered = hoveredIndex, hovered != currentIndex {
            drawHoverIndicator(at: hovered, in: rect)
        }
    }

    private func drawActivityBlocks(in rect: NSRect) {
        // Group frames by app and draw colored blocks
        guard screenshots.count > 0 else { return }

        let blockWidth = rect.width / CGFloat(screenshots.count)

        // Only draw if blocks would be visible (at least 0.5px wide)
        if blockWidth < 0.5 {
            // Too many frames - draw a gradient or simplified view
            let gradient = NSGradient(colors: [
                NSColor(white: 0.3, alpha: 1.0),
                NSColor(white: 0.4, alpha: 1.0)
            ])
            gradient?.draw(in: rect, angle: 0)
            return
        }

        for (index, screenshot) in screenshots.enumerated() {
            let x = rect.minX + CGFloat(index) * blockWidth
            let blockRect = NSRect(x: x, y: rect.minY, width: max(1, blockWidth - 0.5), height: rect.height)
            let color = colorForApp(screenshot.appName)
            color.withAlphaComponent(0.6).setFill()
            NSBezierPath(rect: blockRect).fill()
        }
    }

    private func drawSearchMarkers(indices: Set<Int>, in rect: NSRect) {
        let markerWidth: CGFloat = 3

        for index in indices {
            let x = xPositionForIndex(index)
            let markerRect = NSRect(
                x: x - markerWidth / 2,
                y: rect.minY - 2,
                width: markerWidth,
                height: rect.height + 4
            )
            NSColor.yellow.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: markerRect, xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawPlayhead(in rect: NSRect) {
        let x = xPositionForIndex(currentIndex)
        let playheadWidth: CGFloat = 4
        let playheadHeight: CGFloat = rect.height + 8

        // Playhead line
        let playheadRect = NSRect(
            x: x - playheadWidth / 2,
            y: rect.minY - 4,
            width: playheadWidth,
            height: playheadHeight
        )

        // Glow effect
        let glowRect = playheadRect.insetBy(dx: -2, dy: -2)
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: glowRect, xRadius: 4, yRadius: 4).fill()

        // Main playhead
        NSColor.white.setFill()
        NSBezierPath(roundedRect: playheadRect, xRadius: 2, yRadius: 2).fill()

        // Top triangle indicator
        let triangleSize: CGFloat = 8
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: x, y: rect.minY - 6))
        triangle.line(to: NSPoint(x: x - triangleSize / 2, y: rect.minY - 6 - triangleSize))
        triangle.line(to: NSPoint(x: x + triangleSize / 2, y: rect.minY - 6 - triangleSize))
        triangle.close()
        NSColor.white.setFill()
        triangle.fill()
    }

    private func drawHoverIndicator(at index: Int, in rect: NSRect) {
        let x = xPositionForIndex(index)
        let indicatorWidth: CGFloat = 2

        let indicatorRect = NSRect(
            x: x - indicatorWidth / 2,
            y: rect.minY,
            width: indicatorWidth,
            height: rect.height
        )
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: indicatorRect, xRadius: 1, yRadius: 1).fill()
    }

    private func colorForApp(_ appName: String) -> NSColor {
        // Simple hash-based color
        let hash = abs(appName.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.3, brightness: 0.5, alpha: 1.0)
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
