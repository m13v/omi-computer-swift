import Foundation
import Sentry

private let logFile = "/tmp/omi.log"
private let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

/// Check if this is a development build (avoids Sentry calls in dev)
private let isDevBuild: Bool = Bundle.main.bundleIdentifier?.contains(".development") == true

/// Write to log file, stdout, and Sentry breadcrumbs
func log(_ message: String) {
    let timestamp = dateFormatter.string(from: Date())
    let line = "[\(timestamp)] [app] \(message)"
    print(line)
    fflush(stdout)

    // Add breadcrumb to Sentry for context in crash reports (skip in dev builds)
    if !isDevBuild {
        let breadcrumb = Breadcrumb(level: .info, category: "app")
        breadcrumb.message = message
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    // Append to log file
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}

/// Log an error and capture it in Sentry
func logError(_ message: String, error: Error? = nil) {
    let timestamp = dateFormatter.string(from: Date())
    let errorDesc = error?.localizedDescription ?? ""
    let fullMessage = error != nil ? "\(message): \(errorDesc)" : message
    let line = "[\(timestamp)] [error] \(fullMessage)"
    print(line)
    fflush(stdout)

    // Add error breadcrumb and capture in Sentry (skip in dev builds)
    if !isDevBuild {
        let breadcrumb = Breadcrumb(level: .error, category: "error")
        breadcrumb.message = fullMessage
        SentrySDK.addBreadcrumb(breadcrumb)

        // Capture the error in Sentry
        if let error = error {
            SentrySDK.capture(error: error) { scope in
                scope.setContext(value: ["message": message], key: "app_context")
            }
        } else {
            SentrySDK.capture(message: fullMessage) { scope in
                scope.setLevel(.error)
            }
        }
    }

    // Append to log file
    if let data = (line + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
            if let handle = FileHandle(forWritingAtPath: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logFile, contents: data)
        }
    }
}
