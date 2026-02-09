import Cocoa
import SwiftUI

// MARK: - Test Result Model

struct TaskTestResult: Identifiable {
    let id = UUID()
    let index: Int
    let timestamp: Date
    let appName: String
    let result: TaskExtractionResult?
    let error: String?
    let duration: TimeInterval
}

// MARK: - SwiftUI View

struct TaskTestRunnerView: View {
    @State private var screenshotCount = 10
    @State private var isRunning = false
    @State private var results: [TaskTestResult] = []
    @State private var progress: Double = 0
    @State private var elapsedTime: TimeInterval = 0
    @State private var statusMessage = "Ready"
    @State private var cancellationRequested = false

    var onClose: (() -> Void)?

    private let screenshotOptions = [5, 10, 20, 50]

    private var extractionInterval: TimeInterval {
        TaskAssistantSettings.shared.extractionInterval
    }

    private var periodMinutes: Int {
        Int(Double(screenshotCount) * extractionInterval / 60)
    }

    private var tasksFound: Int {
        results.filter { $0.result?.hasNewTask == true }.count
    }

    private var errorsCount: Int {
        results.filter { $0.error != nil }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(20)

            Divider()

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(results) { result in
                            resultRow(result)
                                .id(result.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: results.count) { _, _ in
                    if let last = results.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Footer
            footer
                .padding(16)
        }
        .frame(width: 700, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task Extraction Test Runner")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("Replay past screenshots through the extraction pipeline")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                // Screenshot count picker
                HStack(spacing: 8) {
                    Text("Screenshots:")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)

                    Picker("", selection: $screenshotCount) {
                        ForEach(screenshotOptions, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .disabled(isRunning)

                    Text("(\(periodMinutes) min)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                // Run / Stop button
                if isRunning {
                    Button(action: { cancellationRequested = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                            Text("Stop")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                } else {
                    Button(action: runTest) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Run Test")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Progress bar
            if isRunning {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .tint(.accentColor)

                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Result Row

    private func resultRow(_ testResult: TaskTestResult) -> some View {
        HStack(spacing: 12) {
            // Index
            Text("\(testResult.index)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            // Timestamp
            Text(testResult.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)

            // App name
            Text(testResult.appName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)

            // Result
            if let error = testResult.error {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            } else if let result = testResult.result {
                if result.hasNewTask, let task = result.task {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text(task.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("(\(Int(task.confidence * 100))%)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(result.contextSummary)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Duration
            Text(String(format: "%.1fs", testResult.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(testResult.result?.hasNewTask == true ? Color.green.opacity(0.05) : Color.clear)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if !results.isEmpty {
                HStack(spacing: 16) {
                    Label("\(results.count)/\(screenshotCount)", systemImage: "photo.stack")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Label("\(tasksFound) tasks", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundColor(tasksFound > 0 ? .green : .secondary)

                    if errorsCount > 0 {
                        Label("\(errorsCount) errors", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    if elapsedTime > 0 {
                        Label(String(format: "%.1fs total", elapsedTime), systemImage: "clock")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text("Select screenshot count and click Run Test")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()

            Button("Done") {
                onClose?()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - Test Execution

    private func runTest() {
        isRunning = true
        results = []
        progress = 0
        elapsedTime = 0
        cancellationRequested = false
        statusMessage = "Loading screenshots..."

        Task {
            let startTime = Date()
            let interval = extractionInterval
            let now = Date()
            let periodStart = now.addingTimeInterval(-Double(screenshotCount) * interval)

            // Get TaskAssistant from coordinator
            guard let assistant = await MainActor.run(body: {
                AssistantCoordinator.shared.assistant(withIdentifier: "task-extraction")
            }) as? TaskAssistant else {
                await MainActor.run {
                    statusMessage = "Task Assistant not available"
                    isRunning = false
                }
                return
            }

            // Sample screenshots at extraction-interval spacing
            for i in 0..<screenshotCount {
                if cancellationRequested { break }

                let targetTime = periodStart.addingTimeInterval(Double(i) * interval)
                await MainActor.run {
                    statusMessage = "Processing \(i + 1)/\(screenshotCount)..."
                }

                do {
                    // Find screenshot closest to target time (30s window)
                    let screenshots = try await RewindDatabase.shared.getScreenshots(
                        from: targetTime.addingTimeInterval(-30),
                        to: targetTime.addingTimeInterval(30),
                        limit: 1
                    )

                    guard let screenshot = screenshots.first else {
                        await MainActor.run {
                            results.append(TaskTestResult(
                                index: i + 1,
                                timestamp: targetTime,
                                appName: "—",
                                result: nil,
                                error: "No screenshot found",
                                duration: 0
                            ))
                            progress = Double(i + 1) / Double(screenshotCount)
                        }
                        continue
                    }

                    // Load JPEG from video chunk
                    let jpegData = try await RewindStorage.shared.loadScreenshotData(for: screenshot)

                    // Run extraction pipeline
                    let analyzeStart = Date()
                    let result = try await assistant.testAnalyze(jpegData: jpegData, appName: screenshot.appName)
                    let duration = Date().timeIntervalSince(analyzeStart)

                    await MainActor.run {
                        results.append(TaskTestResult(
                            index: i + 1,
                            timestamp: screenshot.timestamp,
                            appName: screenshot.appName,
                            result: result,
                            error: nil,
                            duration: duration
                        ))
                        progress = Double(i + 1) / Double(screenshotCount)
                    }
                } catch {
                    await MainActor.run {
                        results.append(TaskTestResult(
                            index: i + 1,
                            timestamp: targetTime,
                            appName: "—",
                            result: nil,
                            error: error.localizedDescription,
                            duration: 0
                        ))
                        progress = Double(i + 1) / Double(screenshotCount)
                    }
                }
            }

            let totalElapsed = Date().timeIntervalSince(startTime)
            await MainActor.run {
                elapsedTime = totalElapsed
                statusMessage = cancellationRequested ? "Stopped" : "Complete"
                isRunning = false
            }
        }
    }
}

// MARK: - NSWindow Subclass

class TaskTestRunnerWindow: NSWindow {
    private static var sharedWindow: TaskTestRunnerWindow?

    static func show() {
        if let existingWindow = sharedWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = TaskTestRunnerWindow()
        sharedWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        sharedWindow?.close()
        sharedWindow = nil
    }

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 700, height: 600)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Task Extraction Test Runner"
        self.isReleasedWhenClosed = false
        self.delegate = self
        self.minSize = NSSize(width: 600, height: 450)
        self.center()

        let runnerView = TaskTestRunnerView(onClose: { [weak self] in
            self?.close()
        })

        let hostingView = NSHostingView(rootView: runnerView)
        self.contentView = hostingView
    }
}

// MARK: - NSWindowDelegate

extension TaskTestRunnerWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        TaskTestRunnerWindow.sharedWindow = nil
    }
}
