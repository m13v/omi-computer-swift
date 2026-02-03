import AppKit
import SwiftUI

/// Controller that manages the glow overlay using edge windows positioned around the target
@MainActor
class OverlayService {
    static let shared = OverlayService()

    /// The 4 edge windows (top, bottom, left, right)
    private var edgeWindows: [GlowEdge: GlowEdgeWindow] = [:]
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the glow effect around the currently active window
    /// - Parameter colorMode: The color mode for the glow (focused = green, distracted = red)
    func showGlowAroundActiveWindow(colorMode: GlowColorMode = .focused) {
        // Check if glow overlay is enabled in settings
        guard AssistantSettings.shared.glowOverlayEnabled else {
            log("Glow overlay disabled in settings, skipping")
            return
        }

        // Get the active window's frame
        guard let windowFrame = getActiveWindowFrame() else {
            log("Could not get active window frame for glow effect")
            return
        }

        showGlow(around: windowFrame, colorMode: colorMode)
    }

    /// Show the glow effect around a specific frame (used for preview)
    /// - Parameters:
    ///   - frame: The frame to show the glow around
    ///   - colorMode: The color mode for the glow (focused = green, distracted = red)
    ///   - isPreview: If true, bypasses the settings check (for preview mode)
    func showGlow(around frame: NSRect, colorMode: GlowColorMode, isPreview: Bool = false) {
        // Check if glow overlay is enabled in settings (unless this is a preview)
        if !isPreview {
            guard AssistantSettings.shared.glowOverlayEnabled else {
                log("Glow overlay disabled in settings, skipping")
                return
            }
        }

        // Dismiss any existing overlay
        dismissOverlay()

        // Create the 4 edge windows
        let edges: [GlowEdge] = [.top, .bottom, .left, .right]

        for edge in edges {
            let edgeWindow = GlowEdgeWindow(edge: edge)

            // Create the SwiftUI glow view for this edge
            let glowView = GlowEdgeView(edge: edge, colorMode: colorMode)
            let hostingView = NSHostingView(rootView: glowView)
            hostingView.frame = edgeWindow.contentView?.bounds ?? .zero
            hostingView.autoresizingMask = [.width, .height]

            edgeWindow.contentView?.addSubview(hostingView)
            edgeWindow.updateFrame(for: frame)

            // Show the window
            edgeWindow.orderFrontRegardless()

            edgeWindows[edge] = edgeWindow
        }

        log("Showing \(colorMode == .focused ? "green" : "red") edge glow effect around window at \(frame)\(isPreview ? " (preview)" : "")")

        // Auto-dismiss after animation completes
        dismissTask = Task {
            do {
                try await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
                await MainActor.run {
                    self.dismissOverlay()
                }
            } catch {
                // Task was cancelled (e.g., new glow shown before this one finished)
            }
        }
    }

    /// Dismiss the overlay windows
    func dismissOverlay() {
        dismissTask?.cancel()
        dismissTask = nil

        for (_, window) in edgeWindows {
            // Remove the content view first to stop SwiftUI animations
            window.contentView?.subviews.forEach { $0.removeFromSuperview() }

            // Disable window animations
            window.animationBehavior = .none

            // Use orderOut instead of close
            window.orderOut(nil)
        }

        edgeWindows.removeAll()
    }

    /// Get the frame of the currently active window
    private func getActiveWindowFrame() -> NSRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let activePID = frontApp.processIdentifier

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        // Collect all windows belonging to the active app
        var appWindows: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = []

        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? Int32,
                  windowPID == activePID else {
                continue
            }

            // Get window bounds
            if let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
               let x = boundsDict["X"],
               let y = boundsDict["Y"],
               let width = boundsDict["Width"],
               let height = boundsDict["Height"],
               width > 100 && height > 100 {
                appWindows.append((x: x, y: y, width: width, height: height))
            }
        }

        // Pick the largest window by area (handles apps like Arc with multiple utility windows)
        guard let largest = appWindows.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }

        // CGWindowList uses top-left origin, but NSWindow uses bottom-left
        // Convert coordinate system
        let screenHeight = NSScreen.main?.frame.height ?? 0
        let flippedY = screenHeight - largest.y - largest.height

        return NSRect(x: largest.x, y: flippedY, width: largest.width, height: largest.height)
    }
}

// MARK: - Backward Compatibility Alias

/// Alias for backward compatibility
typealias GlowOverlayController = OverlayService
