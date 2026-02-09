import Cocoa
import SwiftUI

// MARK: - Test Result Model

struct TaskTestResult: Identifiable {
    let id = UUID()
    let index: Int
    let timestamp: Date
    let appName: String
    let windowTitle: String?
    let result: TaskExtractionResult?
    let error: String?
    let duration: TimeInterval
    let searchCount: Int
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

    private var totalSearches: Int {
        results.reduce(0) { $0 + $1.searchCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
                .padding(20)

            Divider()

            // Column headers
            columnHeaders
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))

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
        .frame(width: 1400, height: 900)
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

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 16) {
            Text("#")
                .frame(width: 28, alignment: .trailing)
            Text("Time")
                .frame(width: 90, alignment: .leading)
            Text("App")
                .frame(width: 100, alignment: .leading)
            Text("Window")
                .frame(width: 150, alignment: .leading)
            Text("Decision")
                .frame(width: 100, alignment: .leading)
            Text("Search")
                .frame(width: 40, alignment: .leading)
            Text("Details")
            Spacer()
            Text("Conf")
                .frame(width: 40, alignment: .trailing)
            Text("Time")
                .frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundColor(.secondary.opacity(0.7))
    }

    // MARK: - Result Row

    private func resultRow(_ testResult: TaskTestResult) -> some View {
        HStack(spacing: 16) {
            // Index
            Text("\(testResult.index)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)

            // Timestamp
            Text(testResult.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)

            // App name
            Text(testResult.appName)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
                .lineLimit(1)

            // Window title
            Text(testResult.windowTitle ?? "—")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)

            // Decision column
            decisionBadge(for: testResult)
                .frame(width: 100, alignment: .leading)

            // Search count indicator
            if testResult.searchCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9))
                    Text("×\(testResult.searchCount)")
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .leading)
            } else {
                Text("")
                    .frame(width: 40)
            }

            // Task title or context summary
            if let error = testResult.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
                    .lineLimit(2)
            } else if let result = testResult.result {
                if result.hasNewTask, let task = result.task {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(task.priority.rawValue)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(priorityColor(task.priority))
                                .cornerRadius(3)
                            Text("\(task.sourceCategory)/\(task.sourceSubcategory)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.purple.opacity(0.7))
                                .cornerRadius(3)
                            Text(task.tags.joined(separator: ", "))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text(result.contextSummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Confidence (only for tasks)
            if let result = testResult.result, result.hasNewTask, let task = result.task {
                Text("\(Int(task.confidence * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.green)
                    .frame(width: 40, alignment: .trailing)
            } else {
                Text("")
                    .frame(width: 40)
            }

            // Duration
            Text(String(format: "%.1fs", testResult.duration))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(testResult.result?.hasNewTask == true ? Color.green.opacity(0.05) : Color.clear)
    }

    private func decisionBadge(for testResult: TaskTestResult) -> some View {
        Group {
            if testResult.error != nil {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Error")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.orange)
            } else if let result = testResult.result {
                if result.hasNewTask {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10))
                        Text("New Task")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.green)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                        Text("No Task")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        }
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

                    Label("\(totalSearches) searches", systemImage: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(totalSearches > 0 ? .blue : .secondary)

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

            // Build filter parameters from current settings
            let (allowedApps, browserApps, browserPatterns) = await MainActor.run { () -> (Set<String>, Set<String>, [String]) in
                let settings = TaskAssistantSettings.shared
                return (settings.allowedApps, TaskAssistantSettings.browserApps, settings.browserKeywords)
            }

            // Fetch screenshots filtered at the SQL level by allowed apps + browser window patterns
            let filtered: [Screenshot]
            do {
                filtered = try await RewindDatabase.shared.getScreenshotsFiltered(
                    from: periodStart,
                    to: now,
                    allowedApps: allowedApps,
                    browserApps: browserApps,
                    browserWindowPatterns: browserPatterns,
                    limit: screenshotCount * 600
                ).reversed()  // getScreenshotsFiltered returns desc, we want chronological
            } catch {
                await MainActor.run {
                    statusMessage = "Failed to load screenshots: \(error.localizedDescription)"
                    isRunning = false
                }
                return
            }

            guard !filtered.isEmpty else {
                await MainActor.run {
                    statusMessage = "No screenshots matched allowed apps & browser filters in the last \(periodMinutes) minutes"
                    isRunning = false
                }
                return
            }

            // Pick N evenly-spaced screenshots from filtered set
            let sampled: [Screenshot]
            if filtered.count <= screenshotCount {
                sampled = Array(filtered)
            } else {
                let step = Double(filtered.count - 1) / Double(screenshotCount - 1)
                sampled = (0..<screenshotCount).map { i in
                    filtered[Int(Double(i) * step)]
                }
            }

            await MainActor.run {
                statusMessage = "Found \(filtered.count) matching screenshots, sampling \(sampled.count)..."
            }

            // Process each sampled screenshot
            for (i, screenshot) in sampled.enumerated() {
                if cancellationRequested { break }

                await MainActor.run {
                    statusMessage = "Processing \(i + 1)/\(sampled.count)..."
                }

                do {
                    // Load JPEG from video chunk
                    let jpegData = try await RewindStorage.shared.loadScreenshotData(for: screenshot)

                    // Run extraction pipeline
                    let analyzeStart = Date()
                    let (result, searchCount) = try await assistant.testAnalyze(jpegData: jpegData, appName: screenshot.appName)
                    let duration = Date().timeIntervalSince(analyzeStart)

                    await MainActor.run {
                        results.append(TaskTestResult(
                            index: i + 1,
                            timestamp: screenshot.timestamp,
                            appName: screenshot.appName,
                            windowTitle: screenshot.windowTitle,
                            result: result,
                            error: nil,
                            duration: duration,
                            searchCount: searchCount
                        ))
                        progress = Double(i + 1) / Double(sampled.count)
                    }
                } catch {
                    await MainActor.run {
                        results.append(TaskTestResult(
                            index: i + 1,
                            timestamp: screenshot.timestamp,
                            appName: screenshot.appName,
                            windowTitle: screenshot.windowTitle,
                            result: nil,
                            error: error.localizedDescription,
                            duration: 0,
                            searchCount: 0
                        ))
                        progress = Double(i + 1) / Double(sampled.count)
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
        let contentRect = NSRect(x: 0, y: 0, width: 1400, height: 900)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        self.title = "Task Extraction Test Runner"
        self.isReleasedWhenClosed = false
        self.delegate = self
        self.minSize = NSSize(width: 900, height: 600)
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
