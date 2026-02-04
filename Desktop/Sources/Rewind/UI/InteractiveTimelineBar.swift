import SwiftUI
import AppKit

/// Compact timeline bar with frame bars and scroll-to-center navigation
/// Inspired by Screenpipe's scrollable timeline approach
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
    private let visibleCount = 400

    var body: some View {
        VStack(spacing: 4) {
            // Timeline using NSScrollView for natural scroll behavior
            ScrollableTimelineView(
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

// MARK: - Scrollable Timeline with NSScrollView

struct ScrollableTimelineView: NSViewRepresentable {
    let screenshots: [Screenshot]
    let currentIndex: Int
    let searchResultIndices: Set<Int>?
    @Binding var hoveredIndex: Int?
    let frameWidth: CGFloat
    let frameSpacing: CGFloat
    let barHeight: CGFloat
    let visibleCount: Int
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> TimelineScrollContainerView {
        let view = TimelineScrollContainerView()
        view.onSelect = onSelect
        view.onHover = { index in
            DispatchQueue.main.async {
                hoveredIndex = index
            }
        }
        return view
    }

    func updateNSView(_ nsView: TimelineScrollContainerView, context: Context) {
        let needsScroll = nsView.currentIndex != currentIndex

        nsView.screenshots = screenshots
        nsView.currentIndex = currentIndex
        nsView.searchResultIndices = searchResultIndices
        nsView.hoveredIndex = hoveredIndex
        nsView.frameWidth = frameWidth
        nsView.frameSpacing = frameSpacing
        nsView.barHeight = barHeight
        nsView.visibleCount = visibleCount
        nsView.onSelect = onSelect

        nsView.updateContentSize()

        if needsScroll {
            nsView.scrollToCurrentIndex(animated: true)
        }
    }
}

// MARK: - Container View with NSScrollView

class TimelineScrollContainerView: NSView {
    var screenshots: [Screenshot] = []
    var currentIndex: Int = 0
    var searchResultIndices: Set<Int>?
    var hoveredIndex: Int?
    var frameWidth: CGFloat = 4
    var frameSpacing: CGFloat = 1
    var barHeight: CGFloat = 32
    var visibleCount: Int = 400
    var onSelect: ((Int) -> Void)?
    var onHover: ((Int?) -> Void)?

    private var scrollView: NSScrollView!
    private var contentView: TimelineContentView!
    private var centerIndicatorView: NSView!
    private var isScrollingProgrammatically = false
    private var lastManualScrollTime: Date = .distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        // Create scroll view
        scrollView = NSScrollView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        // Create content view
        contentView = TimelineContentView(frame: NSRect(x: 0, y: 0, width: 1000, height: bounds.height))
        contentView.parentContainer = self

        scrollView.documentView = contentView
        addSubview(scrollView)

        // Create center indicator (fixed position)
        centerIndicatorView = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: barHeight))
        centerIndicatorView.wantsLayer = true
        centerIndicatorView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
        addSubview(centerIndicatorView)

        // Listen for scroll events
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidEndScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateContentSize()
        positionCenterIndicator()
    }

    private func positionCenterIndicator() {
        let centerX = bounds.width / 2 - 1
        let bottomY = bounds.height - barHeight - 8
        centerIndicatorView.frame = NSRect(x: centerX, y: bottomY, width: 2, height: barHeight)
    }

    func updateContentSize() {
        let totalWidth = CGFloat(screenshots.count) * (frameWidth + frameSpacing)
        let edgePadding = bounds.width / 2 // Padding so first/last frames can be centered
        let contentWidth = totalWidth + edgePadding * 2

        contentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: bounds.height)
        contentView.edgePadding = edgePadding
        contentView.screenshots = screenshots
        contentView.currentIndex = currentIndex
        contentView.searchResultIndices = searchResultIndices
        contentView.hoveredIndex = hoveredIndex
        contentView.frameWidth = frameWidth
        contentView.frameSpacing = frameSpacing
        contentView.barHeight = barHeight
        contentView.visibleCount = visibleCount
        contentView.needsDisplay = true
    }

    func scrollToCurrentIndex(animated: Bool) {
        guard !screenshots.isEmpty else { return }

        let edgePadding = bounds.width / 2
        let frameX = edgePadding + CGFloat(currentIndex) * (frameWidth + frameSpacing)
        let targetX = frameX - bounds.width / 2 + frameWidth / 2

        isScrollingProgrammatically = true

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
            } completionHandler: { [weak self] in
                self?.isScrollingProgrammatically = false
            }
        } else {
            scrollView.contentView.setBoundsOrigin(NSPoint(x: targetX, y: 0))
            isScrollingProgrammatically = false
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        // Update which frame is at center during scroll
        guard !isScrollingProgrammatically else { return }

        // Debounce - don't update too frequently
        let now = Date()
        guard now.timeIntervalSince(lastManualScrollTime) > 0.016 else { return } // ~60fps
        lastManualScrollTime = now

        let centerIndex = indexAtCenter()
        if centerIndex != currentIndex && centerIndex >= 0 && centerIndex < screenshots.count {
            onSelect?(centerIndex)
        }

        contentView.needsDisplay = true
    }

    @objc private func scrollViewDidEndScroll(_ notification: Notification) {
        // Snap to nearest frame when scroll ends
        guard !isScrollingProgrammatically else { return }

        let centerIndex = indexAtCenter()
        if centerIndex >= 0 && centerIndex < screenshots.count {
            onSelect?(centerIndex)
            // Smooth snap to exact center
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.scrollToCurrentIndex(animated: true)
            }
        }
    }

    private func indexAtCenter() -> Int {
        let scrollX = scrollView.contentView.bounds.origin.x
        let centerX = scrollX + bounds.width / 2
        let edgePadding = bounds.width / 2

        let frameX = centerX - edgePadding
        let index = Int(frameX / (frameWidth + frameSpacing))
        return max(0, min(screenshots.count - 1, index))
    }

    func handleClick(at point: CGPoint) {
        let scrollX = scrollView.contentView.bounds.origin.x
        let contentX = point.x + scrollX
        let edgePadding = bounds.width / 2

        let frameX = contentX - edgePadding
        let index = Int(frameX / (frameWidth + frameSpacing))

        if index >= 0 && index < screenshots.count {
            onSelect?(index)
        }
    }

    func handleHover(at point: CGPoint?) {
        guard let point = point else {
            onHover?(nil)
            contentView.hoveredIndex = nil
            contentView.needsDisplay = true
            return
        }

        let scrollX = scrollView.contentView.bounds.origin.x
        let contentX = point.x + scrollX
        let edgePadding = bounds.width / 2

        let frameX = contentX - edgePadding
        let index = Int(frameX / (frameWidth + frameSpacing))

        if index >= 0 && index < screenshots.count {
            onHover?(index)
            contentView.hoveredIndex = index
        } else {
            onHover?(nil)
            contentView.hoveredIndex = nil
        }
        contentView.needsDisplay = true
    }
}

// MARK: - Content View (draws the frames)

class TimelineContentView: NSView {
    weak var parentContainer: TimelineScrollContainerView?

    var screenshots: [Screenshot] = []
    var currentIndex: Int = 0
    var searchResultIndices: Set<Int>?
    var hoveredIndex: Int?
    var frameWidth: CGFloat = 4
    var frameSpacing: CGFloat = 1
    var barHeight: CGFloat = 32
    var visibleCount: Int = 400
    var edgePadding: CGFloat = 0

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

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let windowLocation = superview?.convert(location, to: nil) ?? location

        // Convert to parent container's coordinate space
        if let container = parentContainer {
            let containerLocation = container.convert(windowLocation, from: nil)
            container.handleClick(at: containerLocation)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // Find which frame is at this location
        let frameX = location.x - edgePadding
        let index = Int(frameX / (frameWidth + frameSpacing))

        if index >= 0 && index < screenshots.count {
            hoveredIndex = index
            showTooltip(for: screenshots[index], at: location)
            parentContainer?.onHover?(index)
        } else {
            hoveredIndex = nil
            hideTooltip()
            parentContainer?.onHover?(nil)
        }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hideTooltip()
        parentContainer?.onHover?(nil)
        needsDisplay = true
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

        let bottomY = bounds.height - 8 // Leave space at bottom
        let totalWidth = frameWidth + frameSpacing

        // Calculate visible range based on dirty rect for performance
        let visibleMinX = dirtyRect.minX
        let visibleMaxX = dirtyRect.maxX

        let startIndex = max(0, Int((visibleMinX - edgePadding) / totalWidth) - 1)
        let endIndex = min(screenshots.count, Int((visibleMaxX - edgePadding) / totalWidth) + 2)

        // Guard against invalid range (startIndex > endIndex can happen with edge padding)
        guard startIndex < endIndex else {
            log("TimelineBar: Skipping draw - invalid range startIndex=\(startIndex) endIndex=\(endIndex) screenshots=\(screenshots.count) edgePadding=\(edgePadding) dirtyRect=\(dirtyRect)")
            return
        }

        for i in startIndex..<endIndex {
            let barX = edgePadding + CGFloat(i) * totalWidth

            let isCurrent = i == currentIndex
            let isHovered = i == hoveredIndex
            let isSearchResult = searchResultIndices?.contains(i) ?? false

            // Bar height
            let heightRatio: CGFloat = (isCurrent || isHovered) ? 1.0 : 0.5
            let height = barHeight * heightRatio

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
            let barRect = NSRect(x: barX, y: bottomY - height, width: frameWidth, height: height)
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
