import AppKit
import CoreGraphics
import Foundation

class ScreenCaptureService {
    private let maxSize: CGFloat = 1024
    private let jpegQuality: CGFloat = 0.85

    init() {}

    /// Check if we have screen recording permission
    static func checkPermission() -> Bool {
        // Always return true - let capture fail if no permission
        // This avoids unreliable permission checks on newer macOS
        return true
    }

    /// Open System Preferences to Screen Recording settings
    static func openScreenRecordingPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Get the window ID of the frontmost application's main window
    private static func getActiveWindowID() -> CGWindowID? {
        let (_, windowID) = getActiveWindowInfo()
        return windowID
    }

    /// Get both the active app name and window ID
    static func getActiveWindowInfo() -> (String?, CGWindowID?) {
        // Refresh run loop to get fresh state
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return (nil, nil)
        }

        let appName = frontApp.localizedName
        let activePID = frontApp.processIdentifier

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return (appName, nil)
        }

        // Find the first window belonging to the active app
        for window in windowList {
            guard let windowPID = window[kCGWindowOwnerPID as String] as? Int32,
                  windowPID == activePID else {
                continue
            }

            // Skip windows that are too small (like menu bar items)
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let width = bounds["Width"],
               let height = bounds["Height"],
               width > 100 && height > 100,
               let windowNumber = window[kCGWindowNumber as String] as? CGWindowID {
                return (appName, windowNumber)
            }
        }

        return (appName, nil)
    }

    /// Capture the active window and return as JPEG data
    func captureActiveWindow() -> Data? {
        guard let windowID = Self.getActiveWindowID() else {
            log("No active window ID found")
            return nil
        }

        log("Capturing window ID: \(windowID)")
        // Use screencapture CLI (works on all macOS versions)
        return captureWithScreencapture(windowID: windowID)
    }

    /// Capture window using screencapture CLI
    private func captureWithScreencapture(windowID: CGWindowID) -> Data? {
        let tempPath = NSTemporaryDirectory() + "omi_capture_\(UUID().uuidString).jpg"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-l", String(windowID), "-x", "-o", tempPath]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                log("screencapture failed with exit code: \(process.terminationStatus)")
                return nil
            }

            let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
            try? FileManager.default.removeItem(atPath: tempPath)

            // Load, resize if needed, and re-encode
            guard let nsImage = NSImage(data: data) else {
                return nil
            }

            var finalImage = nsImage
            let size = nsImage.size
            if max(size.width, size.height) > maxSize {
                let ratio = maxSize / max(size.width, size.height)
                let newSize = NSSize(width: size.width * ratio, height: size.height * ratio)
                finalImage = resizeImage(nsImage, to: newSize)
            }

            return jpegData(from: finalImage)

        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            return nil
        }
    }

    /// Resize an NSImage to the specified size
    private func resizeImage(_ image: NSImage, to newSize: NSSize) -> NSImage {
        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    /// Convert NSImage to JPEG data
    private func jpegData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        )
    }
}
