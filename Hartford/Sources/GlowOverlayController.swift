import AppKit
import SwiftUI

/// Controller that manages the glow overlay window
@MainActor
class GlowOverlayController {
    static let shared = GlowOverlayController()

    private var overlayWindow: GlowOverlayWindow?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Show the glow effect around the currently active window
    func showGlowAroundActiveWindow() {
        // Get the active window's frame
        guard let windowFrame = getActiveWindowFrame() else {
            log("Could not get active window frame for glow effect")
            return
        }

        // Dismiss any existing overlay
        dismissOverlay()

        // Create the overlay window
        let overlay = GlowOverlayWindow(contentRect: windowFrame)

        // Create the SwiftUI glow view
        let glowView = GlowBorderView(targetSize: windowFrame.size)
        let hostingView = NSHostingView(rootView: glowView)
        hostingView.frame = overlay.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]

        overlay.contentView?.addSubview(hostingView)
        overlay.updateFrame(to: windowFrame)

        // Show the window
        overlay.orderFrontRegardless()

        self.overlayWindow = overlay

        log("Showing glow effect around window at \(windowFrame)")

        // Auto-dismiss after animation completes
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5 seconds
            await MainActor.run {
                self.dismissOverlay()
            }
        }
    }

    /// Dismiss the overlay window
    func dismissOverlay() {
        dismissTask?.cancel()
        dismissTask = nil

        overlayWindow?.close()
        overlayWindow = nil
    }

    /// Get the frame of the currently active window
    private func getActiveWindowFrame() -> NSRect? {
        // Refresh run loop to get fresh state
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))

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

        // Find the first window belonging to the active app
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

                // CGWindowList uses top-left origin, but NSWindow uses bottom-left
                // Convert coordinate system
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let flippedY = screenHeight - y - height

                return NSRect(x: x, y: flippedY, width: width, height: height)
            }
        }

        return nil
    }
}
