import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

final class ScreenCaptureService: Sendable {
    private let maxSize: CGFloat = 1024
    private let jpegQuality: CGFloat = 0.85

    init() {}

    /// Check if we have screen recording permission by actually testing capture
    /// CGPreflightScreenCaptureAccess can return stale data after code signing changes
    static func checkPermission() -> Bool {
        // First quick check - if CGPreflight says no, definitely no permission
        if !CGPreflightScreenCaptureAccess() {
            log("Screen capture: CGPreflight says no permission")
            return false
        }

        // CGPreflight can return stale data after rebuilds, so test actual capture
        return testCapturePermission()
    }

    /// Test if screen capture actually works by attempting a real capture
    /// This verifies the app has permission, not just cached permission data
    static func testCapturePermission() -> Bool {
        let tempPath = NSTemporaryDirectory() + "omi_permission_test_\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // Try to capture the screen using screencapture CLI
        // This requires Screen Recording permission to succeed
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", tempPath]  // Silent capture of entire screen

        // Suppress any error output
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            // Check if capture succeeded and file was created with content
            if process.terminationStatus == 0,
               let data = try? Data(contentsOf: URL(fileURLWithPath: tempPath)),
               data.count > 100 {
                log("Screen capture test: SUCCESS")
                return true
            }
            log("Screen capture test: FAILED (exit code: \(process.terminationStatus))")
            return false
        } catch {
            logError("Screen capture test failed", error: error)
            return false
        }
    }

    /// Open System Preferences to Screen Recording settings
    static func openScreenRecordingPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Trigger ScreenCaptureKit consent dialog (macOS 14+)
    /// This is SEPARATE from CGRequestScreenCaptureAccess() - it triggers the
    /// ScreenCaptureKit-specific permission for capturing windows/displays.
    @available(macOS 14.0, *)
    static func requestScreenCaptureKitPermission() async -> Bool {
        do {
            // This call triggers the ScreenCaptureKit consent dialog if not already granted
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            log("ScreenCaptureKit: Permission granted or already available")
            return true
        } catch {
            logError("ScreenCaptureKit: Permission request failed", error: error)
            return false
        }
    }

    /// Force re-register this app with Launch Services to ensure it's the authoritative version
    /// This fixes issues where multiple app bundles with the same bundle ID confuse macOS
    /// about which app to grant permissions to.
    static func ensureLaunchServicesRegistration() {
        guard let bundlePath = Bundle.main.bundlePath as String? else {
            log("Launch Services: Failed to get bundle path")
            return
        }

        log("Launch Services: Re-registering \(bundlePath)...")

        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        // -f = force registration even if already registered
        // This makes this specific app bundle authoritative
        process.arguments = ["-f", bundlePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            log("Launch Services: Registration completed (exit code: \(process.terminationStatus))")
        } catch {
            logError("Launch Services: Failed to register", error: error)
        }
    }

    /// Request all screen capture permissions (both traditional TCC and ScreenCaptureKit)
    static func requestAllScreenCapturePermissions() {
        // 0. Ensure this app is the authoritative version in Launch Services
        // This fixes issues where stale registrations from old builds, DMGs, or Trash
        // cause macOS to grant permissions to the wrong app
        ensureLaunchServicesRegistration()

        // 1. Request traditional Screen Recording TCC permission
        CGRequestScreenCaptureAccess()

        // 2. Request ScreenCaptureKit permission (macOS 14+)
        if #available(macOS 14.0, *) {
            Task {
                _ = await requestScreenCaptureKitPermission()
            }
        }

        // 3. Also open System Settings directly as a fallback
        // Sometimes CGRequestScreenCaptureAccess doesn't show a dialog if permission
        // was previously denied or if there's Launch Services confusion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            openScreenRecordingPreferences()
        }
    }

    /// Test if ScreenCaptureKit specifically works (macOS 14+)
    /// Returns true if ScreenCaptureKit consent is granted, false if declined
    @available(macOS 14.0, *)
    static func testScreenCaptureKitPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            log("ScreenCaptureKit test failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Check if ScreenCaptureKit is in a broken state (TCC says yes, but SCK says no)
    /// This happens when the user declines the ScreenCaptureKit dialog or after rebuilds
    @available(macOS 14.0, *)
    static func isScreenCaptureKitBroken() async -> Bool {
        // If traditional TCC is granted but ScreenCaptureKit fails, it's broken
        let tccGranted = CGPreflightScreenCaptureAccess()
        if !tccGranted {
            return false // Not broken, just not granted
        }

        let sckGranted = await testScreenCaptureKitPermission()
        return !sckGranted // Broken if TCC yes but SCK no
    }

    /// Reset screen capture permission using tccutil
    /// This resets BOTH the traditional TCC and ScreenCaptureKit consent
    /// Returns true if reset succeeded
    static func resetScreenCapturePermission() -> Bool {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.omi.computer-macos"
        log("Resetting screen capture permission for \(bundleId) via tccutil...")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "ScreenCapture", bundleId]

        do {
            try process.run()
            process.waitUntilExit()
            let success = process.terminationStatus == 0
            log("tccutil reset ScreenCapture completed with exit code: \(process.terminationStatus)")
            return success
        } catch {
            logError("Failed to run tccutil", error: error)
            return false
        }
    }

    /// Reset screen capture permission and restart the app
    @MainActor
    static func resetScreenCapturePermissionAndRestart() {
        // First ensure this app is the authoritative version in Launch Services
        // This fixes issues where tccutil resets permission for a stale app registration
        ensureLaunchServicesRegistration()

        let success = resetScreenCapturePermission()

        // Track reset completion
        AnalyticsManager.shared.screenCaptureResetCompleted(success: success)

        if success {
            log("Screen capture permission reset, restarting app...")

            guard let bundleURL = Bundle.main.bundleURL as URL? else {
                log("Failed to get bundle URL for restart")
                return
            }

            // Use a shell script to wait briefly, then relaunch the app
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.5 && open \"\(bundleURL.path)\""]

            do {
                try task.run()
                log("Restart scheduled, terminating current instance...")
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
            } catch {
                logError("Failed to schedule restart", error: error)
            }
        } else {
            log("Screen capture permission reset failed")
        }
    }

    /// Get the window ID of the frontmost application's main window
    private static func getActiveWindowID() -> CGWindowID? {
        let (_, _, windowID) = getActiveWindowInfo()
        return windowID
    }

    /// Get the active app name, window title, and window ID
    static func getActiveWindowInfo() -> (appName: String?, windowTitle: String?, windowID: CGWindowID?) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return (nil, nil, nil)
        }

        let appName = frontApp.localizedName
        let activePID = frontApp.processIdentifier

        // Get all on-screen windows
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return (appName, nil, nil)
        }

        // Collect all windows belonging to the active app
        var appWindows: [(title: String?, windowID: CGWindowID, area: CGFloat)] = []

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
                let windowTitle = window[kCGWindowName as String] as? String
                appWindows.append((title: windowTitle, windowID: windowNumber, area: width * height))
            }
        }

        // Pick the largest window by area (handles apps like Arc with multiple utility windows)
        guard let largest = appWindows.max(by: { $0.area < $1.area }) else {
            return (appName, nil, nil)
        }

        return (appName, largest.title, largest.windowID)
    }

    // MARK: - Async Capture (Primary API)

    /// Async capture - main entry point
    func captureActiveWindowAsync() async -> Data? {
        guard let windowID = Self.getActiveWindowID() else {
            log("No active window ID found")
            return nil
        }

        log("Capturing window ID: \(windowID)")

        if #available(macOS 14.0, *) {
            return await captureWithScreenCaptureKit(windowID: windowID)
        } else {
            // Fallback: run screencapture on background thread for macOS 13.x
            return await captureWithScreencaptureAsync(windowID: windowID)
        }
    }

    /// Capture using ScreenCaptureKit (macOS 14.0+)
    @available(macOS 14.0, *)
    private func captureWithScreenCaptureKit(windowID: CGWindowID) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )

            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                log("Window not found in SCShareableContent")
                return nil
            }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.scalesToFit = true
            // Calculate dimensions maintaining aspect ratio (don't create square canvas)
            let windowWidth = window.frame.width
            let windowHeight = window.frame.height
            let aspectRatio = windowWidth / windowHeight
            var configWidth = min(windowWidth, maxSize)
            var configHeight = configWidth / aspectRatio
            if configHeight > maxSize {
                configHeight = maxSize
                configWidth = configHeight * aspectRatio
            }
            config.width = Int(configWidth)
            config.height = Int(configHeight)

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            return jpegData(from: image)
        } catch {
            logError("ScreenCaptureKit error", error: error)
            return nil
        }
    }

    /// Async wrapper for screencapture CLI (macOS 13.x fallback)
    private func captureWithScreencaptureAsync(windowID: CGWindowID) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.captureWithScreencapture(windowID: windowID)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Synchronous Capture (Legacy)

    /// Capture the active window and return as JPEG data (synchronous - legacy)
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
                logError("screencapture failed with exit code: \(process.terminationStatus)")
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

    // MARK: - Image Processing

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

    /// Convert CGImage to JPEG data
    private func jpegData(from cgImage: CGImage) -> Data? {
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(
            width: cgImage.width,
            height: cgImage.height
        ))
        return jpegData(from: nsImage)
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
