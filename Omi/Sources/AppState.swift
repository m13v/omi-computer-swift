import SwiftUI
import Combine
import UserNotifications
import AVFoundation

/// Speaker segment for diarized transcription
struct SpeakerSegment {
    var speaker: Int
    var text: String
    var start: Double
    var end: Double
}

@MainActor
class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false
    @Published var isMonitoring = false
    @Published var currentApp: String?
    @Published var currentWindowTitle: String?
    @Published var lastStatus: FocusStatus?

    // Transcription state
    @Published var isTranscribing = false
    @Published var currentTranscript: String = ""
    @Published var hasMicrophonePermission = false
    @Published var hasSystemAudioPermission = false
    @Published var isSystemAudioSupported = false

    // Permission states for onboarding
    @Published var hasNotificationPermission = false
    @Published var hasScreenRecordingPermission = false
    @Published var hasAutomationPermission = false

    private var screenCaptureService: ScreenCaptureService?
    private var windowMonitor: WindowMonitor?
    private var geminiService: GeminiService?
    private var captureTimer: Timer?

    // Transcription services
    private var audioCaptureService: AudioCaptureService?
    private var transcriptionService: TranscriptionService?
    private var systemAudioCaptureService: Any?  // SystemAudioCaptureService (macOS 14.4+)
    private var audioMixer: AudioMixer?

    // Speaker segments for diarized transcription
    private var speakerSegments: [SpeakerSegment] = []

    // Conversation tracking for auto-save
    private var recordingStartTime: Date?
    private var maxRecordingTimer: Timer?
    private let maxRecordingDuration: TimeInterval = 4 * 60 * 60  // 4 hours

    // Observers for app lifecycle
    private var willTerminateObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?

    // Smart analysis filtering state
    private var lastAnalyzedApp: String?
    private var lastAnalyzedWindowTitle: String?
    private var analysisCooldownEndTime: Date?
    private var pendingContextSwitch = false  // Triggered by app OR window title change
    private let distractionCooldownSeconds: TimeInterval = 60.0

    init() {
        // Load API key from environment or .env file
        loadEnvironment()

        // Setup lifecycle observers for saving conversations
        setupLifecycleObservers()

        // Check if system audio capture is supported (macOS 14.4+)
        // Note: hasSystemAudioPermission stays false until actually tested during onboarding
        if #available(macOS 14.4, *) {
            isSystemAudioSupported = true
        }
    }

    /// Setup observers for app quit and system sleep to finalize conversations
    private func setupLifecycleObservers() {
        // App is about to quit
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isTranscribing {
                    log("App terminating - finalizing conversation")
                    await self.finalizeConversation()
                }
            }
        }

        // Computer is about to sleep
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if self.isTranscribing {
                    log("Computer sleeping - finalizing conversation")
                    await self.finalizeConversation()
                    self.stopTranscriptionServices()
                }
            }
        }
    }

    deinit {
        if let observer = willTerminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    private func loadEnvironment() {
        // Try to load from .env file in various locations
        let envPaths = [
            Bundle.main.path(forResource: ".env", ofType: nil),
            FileManager.default.currentDirectoryPath + "/.env",
            NSHomeDirectory() + "/.hartford.env",
            NSHomeDirectory() + "/.omi.env",
            // Explicit paths for development
            "/Users/matthewdi/omi-computer-swift/.env",
            "/Users/matthewdi/omi/backend/.env"
        ].compactMap { $0 }

        for path in envPaths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                log("Loading environment from: \(path)")
                for line in contents.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                        // Skip comments
                        guard !key.hasPrefix("#") else { continue }
                        let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        setenv(key, value, 1)
                        // Log key names (not values for security)
                        if key.contains("API_KEY") || key.contains("KEY") {
                            log("  Set \(key)=***")
                        }
                    }
                }
                // Don't break - load all .env files to merge keys
            }
        }

        // Log final state of important keys
        if ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"] != nil {
            log("DEEPGRAM_API_KEY is set")
        } else {
            log("WARNING: DEEPGRAM_API_KEY is NOT set")
        }
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func startMonitoring() {
        // Check screen recording permission with actual capture test
        // CGPreflightScreenCaptureAccess can return stale data after rebuilds
        log("Checking screen recording permission...")
        guard ScreenCaptureService.checkPermission() else {
            log("Screen recording permission check FAILED - showing alert")
            showPermissionAlert()
            return
        }
        log("Screen recording permission verified")

        // Initialize services
        screenCaptureService = ScreenCaptureService()

        do {
            geminiService = try GeminiService(
                onAlert: { message in
                    NotificationService.shared.sendNotification(
                        title: "Focus Alert",
                        message: message,
                        applyCooldown: true
                    )
                },
                onStatusChange: { [weak self] status in
                    Task { @MainActor in
                        self?.lastStatus = status
                    }
                },
                onRefocus: { [weak self] in
                    Task { @MainActor in
                        GlowOverlayController.shared.showGlowAroundActiveWindow()
                        // Track focus restored
                        MixpanelManager.shared.focusRestored(app: self?.currentApp ?? "unknown")
                    }
                },
                onDistraction: { [weak self] in
                    Task { @MainActor in
                        GlowOverlayController.shared.showGlowAroundActiveWindow(colorMode: .distracted)
                        // Start cool-down period after distraction detected
                        self?.analysisCooldownEndTime = Date().addingTimeInterval(self?.distractionCooldownSeconds ?? 60.0)
                        log("Distraction cool-down started for \(self?.distractionCooldownSeconds ?? 60)s")

                        // Track distraction event
                        MixpanelManager.shared.distractionDetected(
                            app: self?.currentApp ?? "unknown",
                            windowTitle: self?.currentWindowTitle
                        )
                    }
                }
            )
        } catch {
            showAlert(title: "Error", message: error.localizedDescription)
            return
        }

        // Get initial app state
        let (appName, windowTitle, _) = WindowMonitor.getActiveWindowInfoStatic()
        if let appName = appName {
            currentApp = appName
            currentWindowTitle = windowTitle
            geminiService?.onAppSwitch(newApp: appName)
            // Force initial analysis
            pendingContextSwitch = true
        }

        // Start window monitor for instant app switch detection
        windowMonitor = WindowMonitor { [weak self] appName in
            Task { @MainActor in
                self?.onAppActivated(appName: appName)
            }
        }
        windowMonitor?.start()

        // Start capture timer (every 1 second)
        captureTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.captureFrame()
            }
        }

        isMonitoring = true

        // Track monitoring started
        MixpanelManager.shared.monitoringStarted()

        NotificationService.shared.sendNotification(
            title: "Monitoring Started",
            message: "Watching for distractions...",
            applyCooldown: false
        )

        log("OMI monitoring started")
    }

    func stopMonitoring() {
        // Stop timer
        captureTimer?.invalidate()
        captureTimer = nil

        // Stop window monitor
        windowMonitor?.stop()
        windowMonitor = nil

        // Stop services
        if let service = geminiService {
            Task {
                await service.stop()
            }
        }
        geminiService = nil
        screenCaptureService = nil

        isMonitoring = false
        currentApp = nil
        currentWindowTitle = nil
        lastStatus = nil

        // Reset analysis filtering state
        lastAnalyzedApp = nil
        lastAnalyzedWindowTitle = nil
        analysisCooldownEndTime = nil
        pendingContextSwitch = false

        // Track monitoring stopped
        MixpanelManager.shared.monitoringStopped()

        NotificationService.shared.sendNotification(
            title: "Monitoring Stopped",
            message: "Focus monitoring disabled",
            applyCooldown: false
        )

        log("OMI monitoring stopped")
    }

    private func onAppActivated(appName: String) {
        // Ignore our own app and system dialogs - don't monitor these (causes flickering)
        let ignoredApps = [
            "OMI-COMPUTER",           // Our own app
            "universalAccessAuthWarn", // macOS permission dialog
            "System Settings",         // System Settings app
            "System Preferences",      // Older macOS name
            "SecurityAgent",           // Security prompts
            "UserNotificationCenter"   // Notification center
        ]
        guard !ignoredApps.contains(appName) else { return }
        guard appName != currentApp else { return }
        currentApp = appName
        geminiService?.onAppSwitch(newApp: appName)

        // Mark that we need to analyze on next capture (app switch triggers analysis)
        pendingContextSwitch = true
        log("App switch detected: \(appName)")

        // Capture immediately on app switch for faster response
        captureFrame()
    }

    private func captureFrame() {
        guard isMonitoring, let screenCaptureService = screenCaptureService else { return }

        // Check for window title change (within same app, e.g., browser tab switch)
        let (_, newWindowTitle, _) = WindowMonitor.getActiveWindowInfoStatic()
        if newWindowTitle != currentWindowTitle {
            if let title = newWindowTitle, let oldTitle = currentWindowTitle {
                log("Window title changed: '\(oldTitle)' → '\(title)'")
            }
            currentWindowTitle = newWindowTitle
            pendingContextSwitch = true
        }

        // Determine if we should send this frame for analysis
        let shouldAnalyze = shouldSendForAnalysis()

        if let jpegData = screenCaptureService.captureActiveWindow(),
           let appName = currentApp {
            if shouldAnalyze {
                geminiService?.submitFrame(jpegData: jpegData, appName: appName)
                lastAnalyzedApp = appName
                lastAnalyzedWindowTitle = currentWindowTitle
                pendingContextSwitch = false
            }
        }
    }

    /// Determines whether to send the current frame for analysis based on state
    private func shouldSendForAnalysis() -> Bool {
        // Check 1: Did the user switch apps or window titles? ALWAYS analyze (bypass cool-down)
        if pendingContextSwitch {
            log("Context switch (app/window) detected - sending for analysis")
            // Clear cool-down on context switch since user changed context
            analysisCooldownEndTime = nil
            return true
        }

        // Check 2: Are we in cool-down period after distraction? (only if no context switch)
        if let cooldownEnd = analysisCooldownEndTime {
            if Date() < cooldownEnd {
                // Still in cool-down and no context switch, skip analysis
                return false
            } else {
                // Cool-down expired, clear it
                analysisCooldownEndTime = nil
                log("Distraction cool-down ended")
            }
        }

        // Check 3: Are we focused on the same app AND same window? Skip analysis
        if lastStatus == .focused && currentApp == lastAnalyzedApp && currentWindowTitle == lastAnalyzedWindowTitle {
            // User is focused on the same context, no need to re-analyze
            return false
        }

        // Check 4: Context changed (different app or window title from last analysis)
        if currentApp != lastAnalyzedApp || currentWindowTitle != lastAnalyzedWindowTitle {
            log("Different context from last analysis - sending for analysis")
            return true
        }

        // Default: analyze if status is unknown or distracted
        if lastStatus == nil || lastStatus == .distracted {
            return true
        }

        return false
    }

    func openScreenRecordingPreferences() {
        ScreenCaptureService.openScreenRecordingPreferences()
    }

    func openAutomationPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestNotificationPermission() {
        // Activate app to ensure permission dialog appears
        NSApp.activate(ignoringOtherApps: true)

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
                return
            }

            if granted {
                // Send a test notification to confirm it works
                DispatchQueue.main.async {
                    NotificationService.shared.sendNotification(
                        title: "Notifications Enabled",
                        message: "You'll receive focus alerts from OMI.",
                        applyCooldown: false
                    )
                }
            }
        }
    }

    /// Trigger screen recording permission prompt
    func triggerScreenRecordingPermission() {
        // Use the official API to request screen capture access
        // This shows a system dialog with "Open System Settings" button
        CGRequestScreenCaptureAccess()
    }

    /// Trigger automation permission by attempting to use Apple Events
    nonisolated func triggerAutomationPermission() {
        // Run a simple AppleScript to trigger the permission prompt
        // This must be done on a background thread since it's nonisolated
        Task.detached {
            let script = NSAppleScript(source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            // Then open settings on main thread
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    // MARK: - Permission Status Checks

    /// Check and update all permission states
    func checkAllPermissions() {
        checkNotificationPermission()
        checkScreenRecordingPermission()
        checkAutomationPermission()
        checkMicrophonePermission()
        checkSystemAudioPermission()
    }

    /// Check notification permission status
    func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                self.hasNotificationPermission = settings.authorizationStatus == .authorized
            }
        }
    }

    /// Check screen recording permission status
    func checkScreenRecordingPermission() {
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    /// Check automation permission by attempting to use Apple Events
    func checkAutomationPermission() {
        Task.detached {
            let script = NSAppleScript(source: """
                tell application "System Events"
                    return name of first process whose frontmost is true
                end tell
            """)
            var error: NSDictionary?
            let result = script?.executeAndReturnError(&error)
            let hasPermission = result != nil && error == nil

            await MainActor.run {
                self.hasAutomationPermission = hasPermission
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Permission Required"
        alert.informativeText = "Screen Recording permission is needed.\n\nClick 'Grant Screen Permission' in the menu, then add this app and restart."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Transcription

    /// Toggle transcription on/off
    func toggleTranscription() {
        if isTranscribing {
            stopTranscription()
        } else {
            startTranscription()
        }
    }

    /// Start real-time transcription
    func startTranscription() {
        guard !isTranscribing else { return }

        // Check microphone permission
        guard AudioCaptureService.checkPermission() else {
            requestMicrophonePermission()
            return
        }

        do {
            // Initialize transcription service
            transcriptionService = try TranscriptionService()

            // Initialize audio capture service
            audioCaptureService = AudioCaptureService()

            // Initialize audio mixer for combining mic and system audio
            audioMixer = AudioMixer()

            // Initialize system audio capture if supported (macOS 14.4+)
            if #available(macOS 14.4, *) {
                systemAudioCaptureService = SystemAudioCaptureService()
                log("Transcription: System audio capture initialized (macOS 14.4+)")
            } else {
                log("Transcription: System audio capture not available (requires macOS 14.4+)")
            }

            // Start transcription service first
            transcriptionService?.start(
                onTranscript: { [weak self] segment in
                    Task { @MainActor in
                        self?.handleTranscriptSegment(segment)
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        log("Transcription error: \(error.localizedDescription)")
                        MixpanelManager.shared.recordingError(error: error.localizedDescription)
                        self?.stopTranscription()
                    }
                },
                onConnected: { [weak self] in
                    Task { @MainActor in
                        log("Transcription: Connected to DeepGram")
                        // Start audio capture once connected
                        self?.startAudioCapture()
                    }
                },
                onDisconnected: {
                    log("Transcription: Disconnected from DeepGram")
                }
            )

            isTranscribing = true
            currentTranscript = ""
            speakerSegments = []
            recordingStartTime = Date()

            // Start 4-hour max recording timer
            maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, self.isTranscribing else { return }
                    log("Transcription: 4-hour limit reached - finalizing conversation")
                    await self.finalizeConversation()
                    // Start a new recording session automatically
                    self.stopTranscriptionServices()
                    self.startTranscription()
                }
            }

            // Track transcription started
            MixpanelManager.shared.transcriptionStarted()

            log("Transcription: Starting...")

        } catch {
            MixpanelManager.shared.recordingError(error: error.localizedDescription)
            showAlert(title: "Transcription Error", message: error.localizedDescription)
        }
    }

    /// Start audio capture and pipe to transcription service
    private func startAudioCapture() {
        guard let audioCaptureService = audioCaptureService,
              let audioMixer = audioMixer else { return }

        // Start the audio mixer - it will send stereo audio to transcription service
        audioMixer.start { [weak self] stereoData in
            self?.transcriptionService?.sendAudio(stereoData)
        }

        do {
            // Start microphone capture - sends to mixer channel 0 (left/user)
            try audioCaptureService.startCapture { [weak self] audioData in
                self?.audioMixer?.setMicAudio(audioData)
            }
            log("Transcription: Microphone capture started")

            // Start system audio capture if available (macOS 14.4+)
            if #available(macOS 14.4, *) {
                if let systemService = systemAudioCaptureService as? SystemAudioCaptureService {
                    do {
                        try systemService.startCapture { [weak self] audioData in
                            self?.audioMixer?.setSystemAudio(audioData)
                        }
                        log("Transcription: System audio capture started")
                    } catch {
                        // System audio is optional - continue with mic only
                        log("Transcription: System audio capture failed (continuing with mic only) - \(error.localizedDescription)")
                    }
                }
            }

            log("Transcription: Audio capture started (multichannel)")
        } catch {
            log("Transcription: Failed to start audio capture - \(error.localizedDescription)")
            stopTranscription()
        }
    }

    /// Stop real-time transcription and finalize the conversation
    func stopTranscription() {
        Task {
            await finalizeConversation()
            stopTranscriptionServices()
        }
    }

    /// Stop transcription services without finalizing (internal use)
    private func stopTranscriptionServices() {
        // Calculate word count before stopping
        let wordCount = currentTranscript.split(separator: " ").count

        // Cancel the max recording timer
        maxRecordingTimer?.invalidate()
        maxRecordingTimer = nil

        // Stop system audio capture first (if available)
        if #available(macOS 14.4, *) {
            if let systemService = systemAudioCaptureService as? SystemAudioCaptureService {
                systemService.stopCapture()
            }
        }
        systemAudioCaptureService = nil

        // Stop microphone capture
        audioCaptureService?.stopCapture()
        audioCaptureService = nil

        // Stop audio mixer
        audioMixer?.stop()
        audioMixer = nil

        // Stop transcription service
        transcriptionService?.stop()
        transcriptionService = nil

        isTranscribing = false

        log("Transcription: Final segments count: \(speakerSegments.count)")

        // Clear segments after finalization
        speakerSegments = []
        recordingStartTime = nil

        // Track transcription stopped
        MixpanelManager.shared.transcriptionStopped(wordCount: wordCount)

        log("Transcription: Stopped")
    }

    /// Finalize and save the current conversation to the backend
    private func finalizeConversation() async {
        guard !speakerSegments.isEmpty, let startTime = recordingStartTime else {
            log("Transcription: No segments to save")
            return
        }

        let endTime = Date()
        log("Transcription: Finalizing conversation with \(speakerSegments.count) segments")

        // Convert SpeakerSegment to API request format
        let apiSegments = speakerSegments.map { segment in
            APIClient.TranscriptSegmentRequest(
                text: segment.text,
                speaker: "SPEAKER_\(String(format: "%02d", segment.speaker))",
                speakerId: segment.speaker,
                isUser: segment.speaker == 0,  // Assume speaker 0 is the user
                start: segment.start,
                end: segment.end
            )
        }

        do {
            let response = try await APIClient.shared.createConversationFromSegments(
                segments: apiSegments,
                startedAt: startTime,
                finishedAt: endTime
            )
            log("Transcription: Conversation saved - id=\(response.id), status=\(response.status), discarded=\(response.discarded)")

            // Show notification to user
            NotificationService.shared.sendNotification(
                title: "Conversation Saved",
                message: response.discarded ? "Conversation was too short and was discarded" : "Your conversation has been processed",
                applyCooldown: false
            )
        } catch {
            log("Transcription: Failed to save conversation - \(error.localizedDescription)")
            MixpanelManager.shared.recordingError(error: "Failed to save: \(error.localizedDescription)")

            // Show error notification
            NotificationService.shared.sendNotification(
                title: "Save Failed",
                message: "Could not save conversation: \(error.localizedDescription)",
                applyCooldown: false
            )
        }
    }

    /// Handle incoming transcript segment with speaker diarization
    /// Uses channel index for primary speaker attribution:
    ///   - Channel 0 = microphone = user (speaker 0)
    ///   - Channel 1 = system audio = others (speaker 1+)
    private func handleTranscriptSegment(_ segment: TranscriptionService.TranscriptSegment) {
        // Only process final segments (speechFinal or isFinal)
        guard segment.speechFinal || segment.isFinal else { return }

        // Determine speaker based on channel index
        // Channel 0 = mic = user (speaker 0)
        // Channel 1 = system audio = others (speaker 1+)
        let channelBasedSpeaker = segment.channelIndex == 0 ? 0 : 1

        // Process words and merge by speaker
        let words = segment.words
        guard !words.isEmpty else {
            // Fallback: no words, just append text with channel-based speaker
            if segment.speechFinal && !segment.text.isEmpty {
                appendToTranscript(segment.text)
                log("Transcript [FINAL no words] Ch\(segment.channelIndex) Speaker \(channelBasedSpeaker): \(segment.text)")
            }
            return
        }

        // Word-to-segment aggregation: merge consecutive words from same speaker
        // For channel 1 (system audio), use diarization speaker ID + 1 to distinguish multiple remote speakers
        var newSegments: [SpeakerSegment] = []
        for word in words {
            // Speaker assignment:
            // - Channel 0 (mic): Always speaker 0 (user)
            // - Channel 1 (system): Use diarization speaker + 1, or default to 1
            let speaker: Int
            if segment.channelIndex == 0 {
                speaker = 0  // Mic is always user
            } else {
                // System audio: offset diarization speakers by 1
                // This allows distinguishing multiple remote speakers (1, 2, 3, etc.)
                speaker = (word.speaker ?? 0) + 1
            }

            if let last = newSegments.last, last.speaker == speaker {
                // Same speaker - append word to existing segment
                newSegments[newSegments.count - 1].text += " " + word.punctuatedWord
                newSegments[newSegments.count - 1].end = word.end
            } else {
                // Different speaker - create new segment
                newSegments.append(SpeakerSegment(
                    speaker: speaker,
                    text: word.punctuatedWord,
                    start: word.start,
                    end: word.end
                ))
            }
        }

        // Log new segments from this chunk
        for seg in newSegments {
            let channelLabel = segment.channelIndex == 0 ? "mic" : "sys"
            log("Transcript [NEW] Ch\(segment.channelIndex)(\(channelLabel)) Speaker \(seg.speaker) [\(String(format: "%.1f", seg.start))s-\(String(format: "%.1f", seg.end))s]: \(seg.text)")
        }

        // Gap-based merging: combine with existing segments if same speaker and gap < 3 seconds
        for newSeg in newSegments {
            if let lastIdx = speakerSegments.indices.last,
               speakerSegments[lastIdx].speaker == newSeg.speaker,
               newSeg.start - speakerSegments[lastIdx].end < 3.0 {
                // Same speaker and gap < 3s - merge
                let gap = newSeg.start - speakerSegments[lastIdx].end
                log("Transcript [MERGE] Speaker \(newSeg.speaker) gap=\(String(format: "%.2f", gap))s: merging into existing segment")
                speakerSegments[lastIdx].text += " " + newSeg.text
                speakerSegments[lastIdx].end = newSeg.end
            } else {
                // Different speaker or gap >= 3s - add as new segment
                if let lastIdx = speakerSegments.indices.last {
                    let gap = newSeg.start - speakerSegments[lastIdx].end
                    log("Transcript [ADD] Speaker \(newSeg.speaker) gap=\(String(format: "%.2f", gap))s: new segment (different speaker or gap >= 3s)")
                } else {
                    log("Transcript [ADD] Speaker \(newSeg.speaker): first segment")
                }
                speakerSegments.append(newSeg)
            }
        }

        // Log current segments summary
        log("Transcript [SEGMENTS] Total: \(speakerSegments.count) segments")
        for (i, seg) in speakerSegments.enumerated() {
            let speakerLabel = seg.speaker == 0 ? "user" : "other"
            log("  [\(i)] Speaker \(seg.speaker)(\(speakerLabel)) [\(String(format: "%.1f", seg.start))s-\(String(format: "%.1f", seg.end))s]: \(seg.text)")
        }

        // Update display transcript
        updateTranscriptDisplay()
    }

    /// Update the display transcript from speaker segments
    private func updateTranscriptDisplay() {
        currentTranscript = speakerSegments.map { seg in
            let speakerLabel = seg.speaker == 0 ? "You" : "Speaker \(seg.speaker)"
            return "\(speakerLabel): \(seg.text)"
        }.joined(separator: "\n")
    }

    /// Append text to transcript (fallback when no word-level data)
    private func appendToTranscript(_ text: String) {
        if !currentTranscript.isEmpty {
            currentTranscript += "\n"
        }
        currentTranscript += text
    }

    /// Request microphone permission
    func requestMicrophonePermission() {
        Task {
            let granted = await AudioCaptureService.requestPermission()
            await MainActor.run {
                self.hasMicrophonePermission = granted
                if granted {
                    log("Microphone permission granted")
                    // Only start transcription if onboarding is complete
                    // During onboarding, we just update the permission state
                    if self.hasCompletedOnboarding {
                        self.startTranscription()
                    }
                } else {
                    log("Microphone permission denied")
                    self.showAlert(
                        title: "Microphone Access Required",
                        message: "Please enable microphone access in System Settings > Privacy & Security > Microphone"
                    )
                }
            }
        }
    }

    /// Check microphone permission status
    func checkMicrophonePermission() {
        hasMicrophonePermission = AudioCaptureService.checkPermission()
    }

    /// Check system audio permission status
    /// This checks if the test capture was successful (set by triggerSystemAudioPermission)
    func checkSystemAudioPermission() {
        // Permission is set by triggerSystemAudioPermission after successful test
        // No-op here - we rely on the test result
    }

    /// Trigger system audio permission by actually testing capture
    /// This verifies system audio works by briefly starting and stopping capture
    func triggerSystemAudioPermission() {
        guard #available(macOS 14.4, *) else {
            log("System audio not supported on this macOS version")
            hasSystemAudioPermission = false
            return
        }

        log("System audio: Testing capture...")

        // Create a test capture service
        let testService = SystemAudioCaptureService()

        do {
            // Try to start capture - this will fail if permission is not granted
            try testService.startCapture { _ in
                // We don't need the audio data, just testing if it works
            }

            // If we get here, capture started successfully
            log("System audio: Test capture started successfully")

            // Stop the test capture
            testService.stopCapture()
            log("System audio: Test capture stopped")

            // Mark permission as granted
            hasSystemAudioPermission = true
            log("System audio: Permission verified")

        } catch {
            log("System audio: Test capture failed - \(error.localizedDescription)")
            hasSystemAudioPermission = false

            // Open System Settings to Screen Recording section
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
