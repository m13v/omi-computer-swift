import SwiftUI
import Sparkle

/// Settings page that wraps SettingsView with proper dark theme styling for the main window
struct SettingsPage: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(OmiColors.textPrimary)

                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 24)

                // Settings content - embedded SettingsView with dark theme override
                SettingsContentView(appState: appState)
                    .padding(.horizontal, 32)

                Spacer()
            }
        }
        .background(OmiColors.backgroundSecondary.opacity(0.3))
        .onAppear {
            AnalyticsManager.shared.settingsPageOpened()
        }
    }
}

/// Dark-themed settings content matching the main window style
struct SettingsContentView: View {
    // AppState for transcription control
    @ObservedObject var appState: AppState

    // Pending section to navigate to (set by external navigation requests)
    static var pendingSection: SettingsSection?

    // Updater view model
    @ObservedObject private var updaterViewModel = UpdaterViewModel.shared

    // Master monitoring state (screen analysis)
    @State private var isMonitoring: Bool
    @State private var isToggling: Bool = false
    @State private var permissionError: String?

    // Transcription state
    @State private var isTranscribing: Bool
    @State private var isTogglingTranscription: Bool = false
    @State private var transcriptionError: String?

    // Focus Assistant states
    @State private var focusEnabled: Bool
    @State private var cooldownInterval: Int
    @State private var glowOverlayEnabled: Bool
    @State private var analysisDelay: Int

    // Task Assistant states
    @State private var taskEnabled: Bool
    @State private var taskExtractionInterval: Double
    @State private var taskMinConfidence: Double

    // Advice Assistant states
    @State private var adviceEnabled: Bool
    @State private var adviceExtractionInterval: Double
    @State private var adviceMinConfidence: Double

    // Memory Assistant states
    @State private var memoryEnabled: Bool
    @State private var memoryExtractionInterval: Double
    @State private var memoryMinConfidence: Double
    @State private var memoryNotificationsEnabled: Bool

    // Glow preview state
    @State private var isPreviewRunning: Bool = false

    // Selected section
    @State private var selectedSection: SettingsSection = .general

    // Notification settings (from backend)
    @State private var dailySummaryEnabled: Bool = true
    @State private var dailySummaryHour: Int = 22
    @State private var notificationsEnabled: Bool = true
    @State private var notificationFrequency: Int = 3

    // Privacy settings (from backend)
    @State private var recordingPermissionEnabled: Bool = false
    @State private var privateCloudSyncEnabled: Bool = true

    // Transcription settings (from backend)
    @State private var singleLanguageMode: Bool = false
    @State private var newVocabularyWord: String = ""
    @State private var vocabularyList: [String] = []

    // Language setting
    @State private var userLanguage: String = "en"

    // Loading states
    @State private var isLoadingSettings: Bool = false

    private let cooldownOptions = [1, 2, 5, 10, 15, 30, 60]
    private let analysisDelayOptions = [0, 60, 300] // seconds: instant, 1 min, 5 min
    private let extractionIntervalOptions: [Double] = [10.0, 600.0, 3600.0] // 10s, 10min, 1hr
    private let hourOptions = Array(0...23)
    private let frequencyOptions = [
        (0, "Off"),
        (1, "Minimal"),
        (2, "Low"),
        (3, "Balanced"),
        (4, "High"),
        (5, "Maximum")
    ]
    // Use the full language list from AssistantSettings
    private var languageOptions: [(String, String)] {
        AssistantSettings.supportedLanguages.map { ($0.code, $0.name) }
    }

    // Language auto-detect state (from local settings)
    @State private var transcriptionAutoDetect: Bool = true
    @State private var transcriptionLanguage: String = "en"

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case focus = "Focus"
        case rewind = "Rewind"
        case transcription = "Transcription"
        case notifications = "Notifications"
        case privacy = "Privacy"
        case account = "Account"
        case about = "About"
    }

    // Track if showing developer settings sub-view
    @State private var showingDeveloperSettings: Bool = false

    init(appState: AppState) {
        self.appState = appState
        let settings = AssistantSettings.shared
        _isMonitoring = State(initialValue: ProactiveAssistantsPlugin.shared.isMonitoring)
        _isTranscribing = State(initialValue: appState.isTranscribing)
        _focusEnabled = State(initialValue: FocusAssistantSettings.shared.isEnabled)
        _cooldownInterval = State(initialValue: FocusAssistantSettings.shared.cooldownInterval)
        _glowOverlayEnabled = State(initialValue: settings.glowOverlayEnabled)
        _analysisDelay = State(initialValue: settings.analysisDelay)
        _taskEnabled = State(initialValue: TaskAssistantSettings.shared.isEnabled)
        _taskExtractionInterval = State(initialValue: TaskAssistantSettings.shared.extractionInterval)
        _taskMinConfidence = State(initialValue: TaskAssistantSettings.shared.minConfidence)
        _adviceEnabled = State(initialValue: AdviceAssistantSettings.shared.isEnabled)
        _adviceExtractionInterval = State(initialValue: AdviceAssistantSettings.shared.extractionInterval)
        _adviceMinConfidence = State(initialValue: AdviceAssistantSettings.shared.minConfidence)
        _memoryEnabled = State(initialValue: MemoryAssistantSettings.shared.isEnabled)
        _memoryExtractionInterval = State(initialValue: MemoryAssistantSettings.shared.extractionInterval)
        _memoryMinConfidence = State(initialValue: MemoryAssistantSettings.shared.minConfidence)
        _memoryNotificationsEnabled = State(initialValue: MemoryAssistantSettings.shared.notificationsEnabled)
    }

    /// Computed status text for notifications
    private var notificationStatusText: String {
        if !appState.hasNotificationPermission {
            return "Notifications are disabled"
        } else if appState.isNotificationBannerDisabled {
            return "Enabled but banners are off"
        } else {
            return "Proactive alerts enabled"
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            // Section tabs (hidden when showing developer settings)
            if !showingDeveloperSettings {
                HStack(spacing: 8) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedSection = section
                            }
                        }) {
                            Text(section.rawValue)
                                .font(.system(size: 14, weight: selectedSection == section ? .semibold : .regular))
                                .foregroundColor(selectedSection == section ? OmiColors.textPrimary : OmiColors.textTertiary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedSection == section ? OmiColors.backgroundTertiary : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()
                }
            }

            // Section content
            if showingDeveloperSettings {
                developerSettingsSection
            } else {
                switch selectedSection {
                case .general:
                    generalSection
                case .focus:
                    FocusPage()
                case .rewind:
                    rewindSection
                case .transcription:
                    transcriptionSection
                case .notifications:
                    notificationsSection
                case .privacy:
                    privacySection
                case .account:
                    accountSection
                case .about:
                    aboutSection
                }
            }
        }
        .onAppear {
            loadBackendSettings()
            // Sync transcription state with appState
            isTranscribing = appState.isTranscribing
            // Refresh notification permission state
            appState.checkNotificationPermission()

            // Check for pending section navigation
            if let pending = Self.pendingSection {
                selectedSection = pending
                Self.pendingSection = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantMonitoringStateDidChange)) { notification in
            if let userInfo = notification.userInfo, let state = userInfo["isMonitoring"] as? Bool {
                isMonitoring = state
            }
        }
        .onChange(of: appState.isTranscribing) { _, newValue in
            isTranscribing = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Refresh notification permission when app becomes active (user may have changed it in System Settings)
            appState.checkNotificationPermission()
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(spacing: 20) {
            // Screen Analysis toggle
            settingsCard {
                HStack(spacing: 16) {
                    Circle()
                        .fill(isMonitoring ? OmiColors.success : OmiColors.textTertiary.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: isMonitoring ? OmiColors.success.opacity(0.5) : .clear, radius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Analysis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(permissionError ?? (isMonitoring ? "Analyzing your screen" : "Screen analysis is paused"))
                            .font(.system(size: 13))
                            .foregroundColor(permissionError != nil ? OmiColors.warning : OmiColors.textTertiary)
                    }

                    Spacer()

                    if isToggling {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Toggle("", isOn: $isMonitoring)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: isMonitoring) { _, newValue in
                                toggleMonitoring(enabled: newValue)
                            }
                    }
                }
            }

            // Transcription toggle
            settingsCard {
                HStack(spacing: 16) {
                    Circle()
                        .fill(isTranscribing ? OmiColors.success : OmiColors.textTertiary.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: isTranscribing ? OmiColors.success.opacity(0.5) : .clear, radius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transcription")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(transcriptionError ?? (isTranscribing ? "Recording and transcribing audio" : "Transcription is paused"))
                            .font(.system(size: 13))
                            .foregroundColor(transcriptionError != nil ? OmiColors.warning : OmiColors.textTertiary)
                    }

                    Spacer()

                    if isTogglingTranscription {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Toggle("", isOn: $isTranscribing)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: isTranscribing) { _, newValue in
                                toggleTranscription(enabled: newValue)
                            }
                    }
                }
            }

            // Notifications toggle
            settingsCard {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Circle()
                            .fill(appState.hasNotificationPermission && !appState.isNotificationBannerDisabled
                                  ? OmiColors.success
                                  : (appState.isNotificationBannerDisabled ? OmiColors.warning : OmiColors.textTertiary.opacity(0.3)))
                            .frame(width: 12, height: 12)
                            .shadow(color: appState.hasNotificationPermission && !appState.isNotificationBannerDisabled
                                    ? OmiColors.success.opacity(0.5) : .clear, radius: 6)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notifications")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(OmiColors.textPrimary)

                            Text(notificationStatusText)
                                .font(.system(size: 13))
                                .foregroundColor(appState.isNotificationBannerDisabled ? OmiColors.warning : OmiColors.textTertiary)
                        }

                        Spacer()

                        if appState.hasNotificationPermission && !appState.isNotificationBannerDisabled {
                            // Show enabled badge
                            Text("Enabled")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.green.opacity(0.15))
                                )
                        } else {
                            // Show button to enable or fix
                            Button(action: {
                                appState.openNotificationPreferences()
                            }) {
                                Text(appState.isNotificationBannerDisabled ? "Fix" : "Enable")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(appState.isNotificationBannerDisabled ? OmiColors.warning : OmiColors.purplePrimary)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Warning when banners are disabled
                    if appState.isNotificationBannerDisabled {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.warning)

                            Text("Banners disabled - you won't see visual alerts. Set style to \"Banners\" in System Settings.")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.warning)

                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(OmiColors.warning.opacity(0.1))
                        )
                    }
                }
            }

        }
    }

    // MARK: - Rewind Section

    @ObservedObject private var rewindSettings = RewindSettings.shared

    private var rewindSection: some View {
        VStack(spacing: 20) {
            // Excluded Apps
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Excluded Apps")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Screen capture is paused when these apps are active")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        Button("Reset to Defaults") {
                            rewindSettings.resetToDefaults()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // List of excluded apps
                    if rewindSettings.excludedApps.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.shield")
                                    .font(.system(size: 24))
                                    .foregroundColor(OmiColors.textTertiary)
                                Text("No apps excluded")
                                    .font(.system(size: 13))
                                    .foregroundColor(OmiColors.textTertiary)
                            }
                            .padding(.vertical, 16)
                            Spacer()
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(Array(rewindSettings.excludedApps).sorted(), id: \.self) { appName in
                                ExcludedAppRow(
                                    appName: appName,
                                    onRemove: {
                                        rewindSettings.includeApp(appName)
                                    }
                                )
                            }
                        }
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Add app section
                    AddExcludedAppView(
                        onAdd: { appName in
                            rewindSettings.excludeApp(appName)
                        },
                        excludedApps: rewindSettings.excludedApps
                    )
                }
            }

            // Retention Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Data Retention")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("How long to keep screen recordings")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        Picker("", selection: $rewindSettings.retentionDays) {
                            Text("3 days").tag(3)
                            Text("7 days").tag(7)
                            Text("14 days").tag(14)
                            Text("30 days").tag(30)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                }
            }
        }
    }

    // MARK: - Transcription Section

    private var transcriptionSection: some View {
        VStack(spacing: 20) {
            // Language Mode
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "globe")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Language Mode")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    // Auto-Detect option
                    Button(action: {
                        transcriptionAutoDetect = true
                        AssistantSettings.shared.transcriptionAutoDetect = true
                        updateTranscriptionPreferences(singleLanguageMode: false)
                        restartTranscriptionIfNeeded()
                    }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: transcriptionAutoDetect ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(transcriptionAutoDetect ? OmiColors.purplePrimary : OmiColors.textTertiary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Auto-Detect (Multi-Language)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(OmiColors.textPrimary)

                                Text("Automatically detects and transcribes:")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)

                                // List of supported languages
                                Text("English, Spanish, French, German, Hindi, Russian, Portuguese, Japanese, Italian, Dutch")
                                    .font(.system(size: 11))
                                    .foregroundColor(OmiColors.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(transcriptionAutoDetect ? OmiColors.purplePrimary.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(transcriptionAutoDetect ? OmiColors.purplePrimary.opacity(0.3) : OmiColors.backgroundQuaternary, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    // Single Language option
                    Button(action: {
                        transcriptionAutoDetect = false
                        AssistantSettings.shared.transcriptionAutoDetect = false
                        updateTranscriptionPreferences(singleLanguageMode: true)
                        restartTranscriptionIfNeeded()
                    }) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: !transcriptionAutoDetect ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(!transcriptionAutoDetect ? OmiColors.purplePrimary : OmiColors.textTertiary)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Single Language (Better Accuracy)")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(OmiColors.textPrimary)

                                Text("Best for speaking in one specific language")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)

                                // Language picker (only shown when single language is selected)
                                if !transcriptionAutoDetect {
                                    HStack {
                                        Text("Language:")
                                            .font(.system(size: 12))
                                            .foregroundColor(OmiColors.textTertiary)

                                        Picker("", selection: $transcriptionLanguage) {
                                            ForEach(languageOptions, id: \.0) { option in
                                                Text(option.1).tag(option.0)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        .frame(width: 180)
                                        .onChange(of: transcriptionLanguage) { _, newValue in
                                            AssistantSettings.shared.transcriptionLanguage = newValue
                                            updateLanguage(newValue)
                                            restartTranscriptionIfNeeded()
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(!transcriptionAutoDetect ? OmiColors.purplePrimary.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(!transcriptionAutoDetect ? OmiColors.purplePrimary.opacity(0.3) : OmiColors.backgroundQuaternary, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    // Info about language support
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)

                        Text("Single language mode supports 42 languages including Ukrainian, Russian, and more.")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
            }

            // Custom Vocabulary
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "text.book.closed")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Vocabulary")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Improve recognition of names, brands, and technical terms")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        if !vocabularyList.isEmpty {
                            Text("\(vocabularyList.count) terms")
                                .font(.system(size: 12))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }

                    // Current vocabulary display with removable tags
                    if !vocabularyList.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(vocabularyList, id: \.self) { term in
                                HStack(spacing: 4) {
                                    Text(term)
                                        .font(.system(size: 12))
                                        .foregroundColor(OmiColors.textSecondary)

                                    Button(action: {
                                        removeVocabularyWord(term)
                                    }) {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundColor(OmiColors.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(OmiColors.backgroundQuaternary)
                                )
                            }
                        }
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Add new word input
                    HStack(spacing: 8) {
                        TextField("Add a word...", text: $newVocabularyWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                addVocabularyWord()
                            }

                        Button(action: {
                            addVocabularyWord()
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(newVocabularyWord.trimmingCharacters(in: .whitespaces).isEmpty ? OmiColors.textTertiary : OmiColors.purplePrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(newVocabularyWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Text("Press Enter or click + to add • Click × to remove")
                        .font(.system(size: 11))
                        .foregroundColor(OmiColors.textTertiary)
                }
            }
        }
    }

    /// Add a word to the vocabulary
    private func addVocabularyWord() {
        let word = newVocabularyWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }

        // Don't add duplicates (case-insensitive check)
        guard !vocabularyList.contains(where: { $0.lowercased() == word.lowercased() }) else {
            newVocabularyWord = ""
            return
        }

        vocabularyList.append(word)
        newVocabularyWord = ""
        saveVocabulary()
    }

    /// Remove a word from the vocabulary
    private func removeVocabularyWord(_ word: String) {
        vocabularyList.removeAll { $0 == word }
        saveVocabulary()
    }

    /// Save vocabulary to local settings and backend
    private func saveVocabulary() {
        // Save to local settings
        AssistantSettings.shared.transcriptionVocabulary = vocabularyList

        // Sync to backend
        updateTranscriptionPreferences(vocabulary: vocabularyList.joined(separator: ", "))
    }

    /// Restart transcription if currently running to apply new settings
    private func restartTranscriptionIfNeeded() {
        guard appState.isTranscribing else { return }

        // Stop and restart to apply new language settings
        appState.stopTranscription()

        // Wait a moment for cleanup, then restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.appState.startTranscription()
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(spacing: 20) {
            // Focus Assistant (simplified)
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Focus Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $focusEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: focusEnabled) { _, newValue in
                                FocusAssistantSettings.shared.isEnabled = newValue
                            }
                    }

                    Text("Detect distractions and help you stay focused")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if focusEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        // Analysis Delay Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Analysis Delay")
                                        .font(.system(size: 14))
                                        .foregroundColor(OmiColors.textSecondary)
                                    Text("Wait before analyzing after switching apps")
                                        .font(.system(size: 12))
                                        .foregroundColor(OmiColors.textTertiary)
                                }

                                Spacer()

                                Text(formatAnalysisDelay(analysisDelay))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .frame(width: 80, alignment: .trailing)
                            }

                            Slider(value: Binding(
                                get: { Double(analysisDelaySliderIndex) },
                                set: { analysisDelay = analysisDelayOptions[Int($0)] }
                            ), in: 0...Double(analysisDelayOptions.count - 1), step: 1)
                                .tint(OmiColors.purplePrimary)
                                .onChange(of: analysisDelay) { _, newValue in
                                    AssistantSettings.shared.analysisDelay = newValue
                                }
                        }

                        settingRow(title: "Visual Glow Effect", subtitle: "Show colored border when focus changes") {
                            Toggle("", isOn: $glowOverlayEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .disabled(isPreviewRunning)
                                .onChange(of: glowOverlayEnabled) { _, newValue in
                                    AssistantSettings.shared.glowOverlayEnabled = newValue
                                    if newValue {
                                        startGlowPreview()
                                    }
                                }
                        }
                    }
                }
            }

            // Task Assistant (with extraction interval slider)
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "checklist")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Task Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $taskEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: taskEnabled) { _, newValue in
                                TaskAssistantSettings.shared.isEnabled = newValue
                            }
                    }

                    Text("Extract tasks and action items from your screen")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if taskEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        // Extraction Interval Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Extraction Interval")
                                        .font(.system(size: 14))
                                        .foregroundColor(OmiColors.textSecondary)
                                    Text("How often to scan for new tasks")
                                        .font(.system(size: 12))
                                        .foregroundColor(OmiColors.textTertiary)
                                }

                                Spacer()

                                Text(formatExtractionInterval(taskExtractionInterval))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .frame(width: 80, alignment: .trailing)
                            }

                            Slider(value: Binding(
                                get: { Double(taskIntervalSliderIndex) },
                                set: { taskExtractionInterval = extractionIntervalOptions[Int($0)] }
                            ), in: 0...Double(extractionIntervalOptions.count - 1), step: 1)
                                .tint(OmiColors.purplePrimary)
                                .onChange(of: taskExtractionInterval) { _, newValue in
                                    TaskAssistantSettings.shared.extractionInterval = newValue
                                }
                        }
                    }
                }
            }

            // Advice Assistant (simplified - toggle + frequency slider)
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Advice Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $adviceEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: adviceEnabled) { _, newValue in
                                AdviceAssistantSettings.shared.isEnabled = newValue
                            }
                    }

                    Text("Get proactive tips and suggestions")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if adviceEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        // Advice Frequency Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Frequency")
                                        .font(.system(size: 14))
                                        .foregroundColor(OmiColors.textSecondary)
                                    Text("How often to check for advice opportunities")
                                        .font(.system(size: 12))
                                        .foregroundColor(OmiColors.textTertiary)
                                }

                                Spacer()

                                Text(formatExtractionInterval(adviceExtractionInterval))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .frame(width: 80, alignment: .trailing)
                            }

                            Slider(value: Binding(
                                get: { Double(adviceIntervalSliderIndex) },
                                set: { adviceExtractionInterval = extractionIntervalOptions[Int($0)] }
                            ), in: 0...Double(extractionIntervalOptions.count - 1), step: 1)
                                .tint(OmiColors.purplePrimary)
                                .onChange(of: adviceExtractionInterval) { _, newValue in
                                    AdviceAssistantSettings.shared.extractionInterval = newValue
                                }
                        }
                    }
                }
            }

            // Memory Assistant (with extraction interval slider)
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Memory Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $memoryEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: memoryEnabled) { _, newValue in
                                MemoryAssistantSettings.shared.isEnabled = newValue
                            }
                    }

                    Text("Extract facts and wisdom from your screen")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if memoryEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        // Extraction Interval Slider
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Extraction Interval")
                                        .font(.system(size: 14))
                                        .foregroundColor(OmiColors.textSecondary)
                                    Text("How often to scan for new memories")
                                        .font(.system(size: 12))
                                        .foregroundColor(OmiColors.textTertiary)
                                }

                                Spacer()

                                Text(formatExtractionInterval(memoryExtractionInterval))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(OmiColors.textSecondary)
                                    .frame(width: 80, alignment: .trailing)
                            }

                            Slider(value: Binding(
                                get: { Double(memoryIntervalSliderIndex) },
                                set: { memoryExtractionInterval = extractionIntervalOptions[Int($0)] }
                            ), in: 0...Double(extractionIntervalOptions.count - 1), step: 1)
                                .tint(OmiColors.purplePrimary)
                                .onChange(of: memoryExtractionInterval) { _, newValue in
                                    MemoryAssistantSettings.shared.extractionInterval = newValue
                                }
                        }
                    }
                }
            }

            // Daily Summary
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "text.badge.checkmark")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Daily Summary")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $dailySummaryEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: dailySummaryEnabled) { _, newValue in
                                updateDailySummarySettings(enabled: newValue)
                            }
                    }

                    Text("Receive a daily summary of your conversations and activities")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if dailySummaryEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        settingRow(title: "Summary Time", subtitle: "When to send your daily summary") {
                            Picker("", selection: $dailySummaryHour) {
                                ForEach(hourOptions, id: \.self) { hour in
                                    Text(formatHour(hour)).tag(hour)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                            .onChange(of: dailySummaryHour) { _, newValue in
                                updateDailySummarySettings(hour: newValue)
                            }
                        }
                    }
                }
            }

            // Notification Frequency
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Notifications")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Toggle("", isOn: $notificationsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: notificationsEnabled) { _, newValue in
                                updateNotificationSettings(enabled: newValue)
                            }
                    }

                    Text("Control how often you receive notifications")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    if notificationsEnabled {
                        Divider()
                            .background(OmiColors.backgroundQuaternary)

                        settingRow(title: "Frequency", subtitle: "How often to receive notifications") {
                            Picker("", selection: $notificationFrequency) {
                                ForEach(frequencyOptions, id: \.0) { option in
                                    Text(option.1).tag(option.0)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: notificationFrequency) { _, newValue in
                                updateNotificationSettings(frequency: newValue)
                            }
                        }
                    }
                }
            }

            // Developer Settings Button
            settingsCard {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingDeveloperSettings = true
                    }
                }) {
                    HStack(spacing: 16) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.textTertiary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Developer Settings")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Advanced configuration options")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Developer Settings Section

    private var developerSettingsSection: some View {
        VStack(spacing: 20) {
            // Back button header
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingDeveloperSettings = false
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(OmiColors.purplePrimary)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Developer Settings")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(OmiColors.textPrimary)

                Spacer()

                // Spacer to balance the back button
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 14, weight: .medium))
                }
                .opacity(0)
            }
            .padding(.bottom, 8)

            // Focus Assistant Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Focus Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    settingRow(title: "Focus Cooldown", subtitle: "Minimum time between distraction alerts") {
                        Picker("", selection: $cooldownInterval) {
                            ForEach(cooldownOptions, id: \.self) { minutes in
                                Text(formatMinutes(minutes)).tag(minutes)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        .onChange(of: cooldownInterval) { _, newValue in
                            FocusAssistantSettings.shared.cooldownInterval = newValue
                        }
                    }

                    settingRow(title: "Focus Analysis Prompt", subtitle: "Customize AI instructions for focus analysis") {
                        Button(action: {
                            PromptEditorWindow.show()
                        }) {
                            HStack(spacing: 4) {
                                Text("Edit")
                                    .font(.system(size: 12))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Task Assistant Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "checklist")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Task Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Minimum Confidence Slider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minimum Confidence")
                                    .font(.system(size: 14))
                                    .foregroundColor(OmiColors.textSecondary)
                                Text("Only show tasks above this confidence level")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)
                            }

                            Spacer()

                            Text("\(Int(taskMinConfidence * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(OmiColors.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }

                        Slider(value: $taskMinConfidence, in: 0.3...0.9, step: 0.1)
                            .tint(OmiColors.purplePrimary)
                            .onChange(of: taskMinConfidence) { _, newValue in
                                TaskAssistantSettings.shared.minConfidence = newValue
                            }
                    }

                    settingRow(title: "Task Extraction Prompt", subtitle: "Customize AI instructions for task extraction") {
                        Button(action: {
                            TaskPromptEditorWindow.show()
                        }) {
                            HStack(spacing: 4) {
                                Text("Edit")
                                    .font(.system(size: 12))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Advice Assistant Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Advice Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Minimum Confidence Slider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minimum Confidence")
                                    .font(.system(size: 14))
                                    .foregroundColor(OmiColors.textSecondary)
                                Text("Only show advice above this confidence level")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)
                            }

                            Spacer()

                            Text("\(Int(adviceMinConfidence * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(OmiColors.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }

                        Slider(value: $adviceMinConfidence, in: 0.5...0.95, step: 0.05)
                            .tint(OmiColors.purplePrimary)
                            .onChange(of: adviceMinConfidence) { _, newValue in
                                AdviceAssistantSettings.shared.minConfidence = newValue
                            }
                    }

                    settingRow(title: "Advice Prompt", subtitle: "Customize AI instructions for advice") {
                        Button(action: {
                            AdvicePromptEditorWindow.show()
                        }) {
                            HStack(spacing: 4) {
                                Text("Edit")
                                    .font(.system(size: 12))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Memory Assistant Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Memory Assistant")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Minimum Confidence Slider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minimum Confidence")
                                    .font(.system(size: 14))
                                    .foregroundColor(OmiColors.textSecondary)
                                Text("Only save memories above this confidence level")
                                    .font(.system(size: 12))
                                    .foregroundColor(OmiColors.textTertiary)
                            }

                            Spacer()

                            Text("\(Int(memoryMinConfidence * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(OmiColors.textSecondary)
                                .frame(width: 40, alignment: .trailing)
                        }

                        Slider(value: $memoryMinConfidence, in: 0.5...0.95, step: 0.05)
                            .tint(OmiColors.purplePrimary)
                            .onChange(of: memoryMinConfidence) { _, newValue in
                                MemoryAssistantSettings.shared.minConfidence = newValue
                            }
                    }

                    settingRow(title: "Show Notifications", subtitle: "Show notification when a memory is extracted") {
                        Toggle("", isOn: $memoryNotificationsEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: memoryNotificationsEnabled) { _, newValue in
                                MemoryAssistantSettings.shared.notificationsEnabled = newValue
                            }
                    }

                    settingRow(title: "Memory Extraction Prompt", subtitle: "Customize AI instructions for memory extraction") {
                        Button(action: {
                            MemoryPromptEditorWindow.show()
                        }) {
                            HStack(spacing: 4) {
                                Text("Edit")
                                    .font(.system(size: 12))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Privacy Section

    private var privacySection: some View {
        VStack(spacing: 20) {
            // Recording Permission
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Store Recordings")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Allow Omi to store audio recordings of your conversations")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $recordingPermissionEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: recordingPermissionEnabled) { _, newValue in
                                updateRecordingPermission(newValue)
                            }
                    }
                }
            }

            // Private Cloud Sync
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Private Cloud Sync")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Sync your data securely to your private cloud storage")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()

                        Toggle("", isOn: $privateCloudSyncEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: privateCloudSyncEnabled) { _, newValue in
                                updatePrivateCloudSync(newValue)
                            }
                    }
                }
            }

            // Data Management
            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Data & Privacy")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Manage your data and privacy settings")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Button("Manage") {
                        if let url = URL(string: "https://omi.me/privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Account Section

    private var accountSection: some View {
        VStack(spacing: 20) {
            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(OmiColors.textTertiary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(AuthService.shared.displayName.isEmpty ? "User" : AuthService.shared.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        if let email = AuthState.shared.userEmail {
                            Text(email)
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }
                    }

                    Spacer()

                    Button("Sign Out") {
                        ProactiveAssistantsPlugin.shared.stopMonitoring()
                        try? AuthService.shared.signOut()
                    }
                    .buttonStyle(.bordered)
                }
            }

//            settingsCard {
//                HStack(spacing: 16) {
//                    Image(systemName: "bolt.fill")
//                        .font(.system(size: 16))
//                        .foregroundColor(.yellow)
//
//                    VStack(alignment: .leading, spacing: 4) {
//                        Text("Upgrade to Pro")
//                            .font(.system(size: 15, weight: .medium))
//                            .foregroundColor(OmiColors.textPrimary)
//
//                        Text("Unlock all features and unlimited usage")
//                            .font(.system(size: 13))
//                            .foregroundColor(OmiColors.textTertiary)
//                    }
//
//                    Spacer()
//
//                    Button("Upgrade") {
//                        if let url = URL(string: "https://omi.me/pricing") {
//                            NSWorkspace.shared.open(url)
//                        }
//                    }
//                    .buttonStyle(.borderedProminent)
//                    .tint(OmiColors.purplePrimary)
//                }
//            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 20) {
            settingsCard {
                VStack(spacing: 16) {
                    // App info
                    HStack(spacing: 16) {
                        if let logoImage = NSImage(contentsOf: Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png")!) {
                            Image(nsImage: logoImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Omi")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Version \(updaterViewModel.currentVersion) (\(updaterViewModel.buildNumber))")
                                .font(.system(size: 13))
                                .foregroundColor(OmiColors.textTertiary)
                        }

                        Spacer()
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    // Links
                    linkRow(title: "Visit Website", url: "https://omi.me")
                    linkRow(title: "Help Center", url: "https://help.omi.me")
                    linkRow(title: "Privacy Policy", url: "https://omi.me/privacy")
                    linkRow(title: "Terms of Service", url: "https://omi.me/terms")
                }
            }

            // Software Updates
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Software Updates")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()

                        Button("Check Now") {
                            updaterViewModel.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!updaterViewModel.canCheckForUpdates)
                    }

                    if let lastCheck = updaterViewModel.lastUpdateCheckDate {
                        Text("Last checked: \(lastCheck, style: .relative) ago")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    settingRow(title: "Automatic Updates", subtitle: "Check for updates automatically in the background") {
                        Toggle("", isOn: $updaterViewModel.automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
            }

            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "exclamationmark.bubble.fill")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Report an Issue")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Help us improve Omi")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Button("Report") {
                        FeedbackWindow.show(userEmail: AuthState.shared.userEmail)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Helper Views

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(OmiColors.backgroundTertiary.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(OmiColors.backgroundQuaternary.opacity(0.3), lineWidth: 1)
                    )
            )
    }

    private func settingRow<Content: View>(title: String, subtitle: String, @ViewBuilder control: () -> Content) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textSecondary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
            }

            Spacer()

            control()
        }
    }

    private func linkRow(title: String, url: String) -> some View {
        Button(action: {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(OmiColors.textSecondary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Language Helpers

    /// Whether the selected language supports auto-detect mode
    private var autoDetectSupported: Bool {
        AssistantSettings.supportsAutoDetect(transcriptionLanguage)
    }

    /// Subtitle text for auto-detect toggle
    private var autoDetectSubtitle: String {
        if autoDetectSupported {
            return "Automatically detect spoken language"
        } else {
            return "Not available for \(languageName(for: transcriptionLanguage))"
        }
    }

    /// Get display name for a language code
    private func languageName(for code: String) -> String {
        AssistantSettings.supportedLanguages.first { $0.code == code }?.name ?? code
    }

    // MARK: - Slider Index Helpers

    private var analysisDelaySliderIndex: Int {
        analysisDelayOptions.firstIndex(of: analysisDelay) ?? 0
    }

    private var taskIntervalSliderIndex: Int {
        extractionIntervalOptions.firstIndex(of: taskExtractionInterval) ?? 0
    }

    private var adviceIntervalSliderIndex: Int {
        extractionIntervalOptions.firstIndex(of: adviceExtractionInterval) ?? 0
    }

    private var memoryIntervalSliderIndex: Int {
        extractionIntervalOptions.firstIndex(of: memoryExtractionInterval) ?? 0
    }

    // MARK: - Helpers

    private func toggleMonitoring(enabled: Bool) {
        if enabled && !ProactiveAssistantsPlugin.shared.hasScreenRecordingPermission {
            permissionError = "Screen recording permission required"
            isMonitoring = false
            ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
            return
        }

        permissionError = nil
        isToggling = true

        // Track setting change
        AnalyticsManager.shared.settingToggled(setting: "monitoring", enabled: enabled)

        if enabled {
            ProactiveAssistantsPlugin.shared.startMonitoring { success, error in
                DispatchQueue.main.async {
                    isToggling = false
                    if !success {
                        permissionError = error ?? "Failed to start monitoring"
                        isMonitoring = false
                    }
                }
            }
        } else {
            ProactiveAssistantsPlugin.shared.stopMonitoring()
            isToggling = false
        }

        // Persist the setting
        AssistantSettings.shared.screenAnalysisEnabled = enabled
    }

    private func toggleTranscription(enabled: Bool) {
        // Check microphone permission
        if enabled && !appState.hasMicrophonePermission {
            transcriptionError = "Microphone permission required"
            isTranscribing = false
            return
        }

        transcriptionError = nil
        isTogglingTranscription = true

        // Track setting change
        AnalyticsManager.shared.settingToggled(setting: "transcription", enabled: enabled)

        if enabled {
            appState.startTranscription()
            isTogglingTranscription = false
            isTranscribing = true
        } else {
            appState.stopTranscription()
            isTogglingTranscription = false
            isTranscribing = false
        }

        // Persist the setting
        AssistantSettings.shared.transcriptionEnabled = enabled
    }

    private func startGlowPreview() {
        isPreviewRunning = true

        // Show the demo window and get its frame
        let demoWindow = GlowDemoWindow.show()
        let windowFrame = demoWindow.frame

        // Phase 1: Show focused (green) glow after a small delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            GlowDemoWindow.setPhase(.focused)
            OverlayService.shared.showGlow(around: windowFrame, colorMode: .focused, isPreview: true)
        }

        // Phase 2: Show distracted (red) glow
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) {
            GlowDemoWindow.setPhase(.distracted)
            OverlayService.shared.showGlow(around: windowFrame, colorMode: .distracted, isPreview: true)
        }

        // End preview and close demo window
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) {
            GlowDemoWindow.close()
            isPreviewRunning = false
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes == 1 {
            return "1 minute"
        } else if minutes < 60 {
            return "\(minutes) minutes"
        } else {
            return "1 hour"
        }
    }

    private func formatAnalysisDelay(_ seconds: Int) -> String {
        if seconds == 0 {
            return "Instant"
        } else if seconds < 60 {
            return "\(seconds) seconds"
        } else if seconds == 60 {
            return "1 minute"
        } else {
            return "\(seconds / 60) minutes"
        }
    }

    private func formatExtractionInterval(_ seconds: Double) -> String {
        if seconds < 60 {
            return "\(Int(seconds)) seconds"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        } else {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
    }

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:00 a"
        var components = DateComponents()
        components.hour = hour
        if let date = Calendar.current.date(from: components) {
            return formatter.string(from: date)
        }
        return "\(hour):00"
    }

    // MARK: - Backend Settings

    private func loadBackendSettings() {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true

        // Load local transcription settings first (these are used immediately)
        transcriptionLanguage = AssistantSettings.shared.transcriptionLanguage
        transcriptionAutoDetect = AssistantSettings.shared.transcriptionAutoDetect
        vocabularyList = AssistantSettings.shared.transcriptionVocabulary

        Task {
            do {
                // Load all settings in parallel
                async let dailySummaryTask = APIClient.shared.getDailySummarySettings()
                async let notificationsTask = APIClient.shared.getNotificationSettings()
                async let languageTask = APIClient.shared.getUserLanguage()
                async let recordingTask = APIClient.shared.getRecordingPermission()
                async let cloudSyncTask = APIClient.shared.getPrivateCloudSync()
                async let transcriptionTask = APIClient.shared.getTranscriptionPreferences()

                let (dailySummary, notifications, language, recording, cloudSync, transcription) = try await (
                    dailySummaryTask,
                    notificationsTask,
                    languageTask,
                    recordingTask,
                    cloudSyncTask,
                    transcriptionTask
                )

                await MainActor.run {
                    dailySummaryEnabled = dailySummary.enabled
                    dailySummaryHour = dailySummary.hour
                    notificationsEnabled = notifications.enabled
                    notificationFrequency = notifications.frequency
                    userLanguage = language.language
                    recordingPermissionEnabled = recording.enabled
                    privateCloudSyncEnabled = cloudSync.enabled
                    singleLanguageMode = transcription.singleLanguageMode
                    vocabularyList = transcription.vocabulary
                    // Sync backend vocabulary to local settings
                    AssistantSettings.shared.transcriptionVocabulary = transcription.vocabulary

                    // Sync backend language to local if different (backend is source of truth for language)
                    if !language.language.isEmpty && language.language != transcriptionLanguage {
                        transcriptionLanguage = language.language
                        AssistantSettings.shared.transcriptionLanguage = language.language
                    }

                    // Sync single language mode from backend (inverted to auto-detect)
                    // Only update if we got a valid response and it differs
                    let backendAutoDetect = !transcription.singleLanguageMode
                    if backendAutoDetect != transcriptionAutoDetect {
                        transcriptionAutoDetect = backendAutoDetect
                        AssistantSettings.shared.transcriptionAutoDetect = backendAutoDetect
                    }

                    isLoadingSettings = false
                }
            } catch {
                logError("Failed to load backend settings", error: error)
                await MainActor.run {
                    isLoadingSettings = false
                }
            }
        }
    }

    private func updateDailySummarySettings(enabled: Bool? = nil, hour: Int? = nil) {
        Task {
            do {
                let _ = try await APIClient.shared.updateDailySummarySettings(enabled: enabled, hour: hour)
            } catch {
                logError("Failed to update daily summary settings", error: error)
            }
        }
    }

    private func updateNotificationSettings(enabled: Bool? = nil, frequency: Int? = nil) {
        Task {
            do {
                let _ = try await APIClient.shared.updateNotificationSettings(enabled: enabled, frequency: frequency)
            } catch {
                logError("Failed to update notification settings", error: error)
            }
        }
    }

    private func updateLanguage(_ language: String) {
        // Track language change
        AnalyticsManager.shared.languageChanged(language: language)

        Task {
            do {
                let _ = try await APIClient.shared.updateUserLanguage(language)
            } catch {
                logError("Failed to update language", error: error)
            }
        }
    }

    private func updateRecordingPermission(_ enabled: Bool) {
        Task {
            do {
                try await APIClient.shared.setRecordingPermission(enabled: enabled)
            } catch {
                logError("Failed to update recording permission", error: error)
            }
        }
    }

    private func updatePrivateCloudSync(_ enabled: Bool) {
        Task {
            do {
                try await APIClient.shared.setPrivateCloudSync(enabled: enabled)
            } catch {
                logError("Failed to update private cloud sync", error: error)
            }
        }
    }

    private func updateTranscriptionPreferences(singleLanguageMode: Bool? = nil, vocabulary: String? = nil) {
        Task {
            do {
                var vocabArray: [String]? = nil
                if let vocab = vocabulary {
                    vocabArray = vocab.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                }
                let _ = try await APIClient.shared.updateTranscriptionPreferences(
                    singleLanguageMode: singleLanguageMode,
                    vocabulary: vocabArray
                )
            } catch {
                logError("Failed to update transcription preferences", error: error)
            }
        }
    }
}

// MARK: - Excluded App Row

struct ExcludedAppRow: View {
    let appName: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(appName: appName, size: 24)

            Text(appName)
                .font(.system(size: 14))
                .foregroundColor(OmiColors.textPrimary)

            Spacer()

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isHovered ? OmiColors.error : OmiColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? OmiColors.backgroundQuaternary.opacity(0.5) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Add Excluded App View

struct AddExcludedAppView: View {
    let onAdd: (String) -> Void
    let excludedApps: Set<String>

    @State private var newAppName: String = ""
    @State private var showingSuggestions = false
    @State private var runningApps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add App to Exclusion List")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OmiColors.textSecondary)

            HStack(spacing: 8) {
                TextField("App name (e.g., Passwords)", text: $newAppName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addApp()
                    }

                Button("Add") {
                    addApp()
                }
                .buttonStyle(.bordered)
                .disabled(newAppName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Running apps suggestions
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Currently Running Apps")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)

                    Spacer()

                    Button {
                        refreshRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(OmiColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(runningApps.filter { !excludedApps.contains($0) }, id: \.self) { appName in
                            RunningAppChip(appName: appName) {
                                onAdd(appName)
                            }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .onAppear {
            refreshRunningApps()
        }
    }

    private func addApp() {
        let trimmed = newAppName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        newAppName = ""
    }

    private func refreshRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .compactMap { $0.localizedName }
            .filter { !$0.isEmpty }
            .sorted()

        // Remove duplicates while preserving order
        var seen = Set<String>()
        runningApps = apps.filter { seen.insert($0).inserted }
    }
}

// MARK: - Running App Chip

struct RunningAppChip: View {
    let appName: String
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                AppIconView(appName: appName, size: 16)

                Text(appName)
                    .font(.system(size: 12))
                    .foregroundColor(OmiColors.textSecondary)

                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(isHovered ? OmiColors.purplePrimary : OmiColors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? OmiColors.backgroundQuaternary : OmiColors.backgroundTertiary.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    SettingsPage(appState: AppState())
}
