import SwiftUI

/// Settings page that wraps SettingsView with proper dark theme styling for the main window
struct SettingsPage: View {
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
                SettingsContentView()
                    .padding(.horizontal, 32)

                Spacer()
            }
        }
        .background(OmiColors.backgroundSecondary.opacity(0.3))
    }
}

/// Dark-themed settings content matching the main window style
struct SettingsContentView: View {
    // Master monitoring state
    @State private var isMonitoring: Bool
    @State private var isToggling: Bool = false
    @State private var permissionError: String?

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

    // Glow preview state
    @State private var isPreviewRunning: Bool = false

    // Selected section
    @State private var selectedSection: SettingsSection = .proactiveAssistant

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
    @State private var customVocabulary: String = ""

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
    private let languageOptions = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh", "Chinese"),
        ("vi", "Vietnamese")
    ]

    enum SettingsSection: String, CaseIterable {
        case proactiveAssistant = "Proactive Assistant"
        case notifications = "Notifications"
        case privacy = "Privacy"
        case account = "Account"
        case about = "About"
    }

    init() {
        let settings = AssistantSettings.shared
        _isMonitoring = State(initialValue: ProactiveAssistantsPlugin.shared.isMonitoring)
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
    }

    var body: some View {
        VStack(spacing: 24) {
            // Section tabs
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

            // Section content
            switch selectedSection {
            case .proactiveAssistant:
                proactiveAssistantSection
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
        .onAppear {
            loadBackendSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .assistantMonitoringStateDidChange)) { notification in
            if let userInfo = notification.userInfo, let state = userInfo["isMonitoring"] as? Bool {
                isMonitoring = state
            }
        }
    }

    // MARK: - Proactive Assistant Section

    private var proactiveAssistantSection: some View {
        VStack(spacing: 20) {
            // Master monitoring toggle
            settingsCard {
                HStack(spacing: 16) {
                    Circle()
                        .fill(isMonitoring ? OmiColors.success : OmiColors.textTertiary.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: isMonitoring ? OmiColors.success.opacity(0.5) : .clear, radius: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Proactive Monitoring")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(OmiColors.textPrimary)

                        Text(permissionError ?? (isMonitoring ? "Analyzing your screen" : "Monitoring is paused"))
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

            // Focus Assistant
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

                        // Analysis Delay
                        settingRow(title: "Analysis Delay", subtitle: "Wait before analyzing after switching apps") {
                            Picker("", selection: $analysisDelay) {
                                ForEach(analysisDelayOptions, id: \.self) { seconds in
                                    Text(formatAnalysisDelay(seconds)).tag(seconds)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: analysisDelay) { _, newValue in
                                AssistantSettings.shared.analysisDelay = newValue
                            }
                        }

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
            }

            // Task Assistant
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

                        settingRow(title: "Extraction Interval", subtitle: "How often to scan for new tasks") {
                            Picker("", selection: $taskExtractionInterval) {
                                ForEach(extractionIntervalOptions, id: \.self) { seconds in
                                    Text(formatExtractionInterval(seconds)).tag(seconds)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: taskExtractionInterval) { _, newValue in
                                TaskAssistantSettings.shared.extractionInterval = newValue
                            }
                        }

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
            }

            // Advice Assistant
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

                        settingRow(title: "Advice Interval", subtitle: "How often to check for advice opportunities") {
                            Picker("", selection: $adviceExtractionInterval) {
                                ForEach(extractionIntervalOptions, id: \.self) { seconds in
                                    Text(formatExtractionInterval(seconds)).tag(seconds)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: adviceExtractionInterval) { _, newValue in
                                AdviceAssistantSettings.shared.extractionInterval = newValue
                            }
                        }

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
            }

            // Memory Assistant
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

                        settingRow(title: "Extraction Interval", subtitle: "How often to scan for new memories") {
                            Picker("", selection: $memoryExtractionInterval) {
                                ForEach(extractionIntervalOptions, id: \.self) { seconds in
                                    Text(formatExtractionInterval(seconds)).tag(seconds)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                            .onChange(of: memoryExtractionInterval) { _, newValue in
                                MemoryAssistantSettings.shared.extractionInterval = newValue
                            }
                        }

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

            // Screen Recording Permission
            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen Recording Permission")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Required for proactive monitoring")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Button("Grant Access") {
                        ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OmiColors.purplePrimary)
                }
            }
        }
    }

    // MARK: - Notifications Section

    private var notificationsSection: some View {
        VStack(spacing: 20) {
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

            // Language
            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundColor(OmiColors.purplePrimary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Language")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Preferred language for transcription and summaries")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Picker("", selection: $userLanguage) {
                        ForEach(languageOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .onChange(of: userLanguage) { _, newValue in
                        updateLanguage(newValue)
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

            // Transcription Settings
            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundColor(OmiColors.purplePrimary)

                        Text("Transcription")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Spacer()
                    }

                    Text("Configure how Omi transcribes your conversations")
                        .font(.system(size: 13))
                        .foregroundColor(OmiColors.textTertiary)

                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    settingRow(title: "Single Language Mode", subtitle: "Disable automatic language translation") {
                        Toggle("", isOn: $singleLanguageMode)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .onChange(of: singleLanguageMode) { _, newValue in
                                updateTranscriptionPreferences(singleLanguageMode: newValue)
                            }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Custom Vocabulary")
                            .font(.system(size: 14))
                            .foregroundColor(OmiColors.textSecondary)

                        Text("Add words to improve transcription accuracy (comma-separated)")
                            .font(.system(size: 12))
                            .foregroundColor(OmiColors.textTertiary)

                        TextField("e.g., Omi, Claude, API", text: $customVocabulary)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                updateTranscriptionPreferences(vocabulary: customVocabulary)
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

            settingsCard {
                HStack(spacing: 16) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.yellow)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upgrade to Pro")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)

                        Text("Unlock all features and unlimited usage")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Button("Upgrade") {
                        if let url = URL(string: "https://omi.me/pricing") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(OmiColors.purplePrimary)
                }
            }
        }
    }

    // MARK: - About Section

    private var aboutSection: some View {
        VStack(spacing: 20) {
            settingsCard {
                VStack(spacing: 16) {
                    // App info
                    HStack(spacing: 16) {
                        if let logoImage = NSImage(contentsOf: Bundle.module.url(forResource: "herologo", withExtension: "png")!) {
                            Image(nsImage: logoImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Omi")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(OmiColors.textPrimary)

                            Text("Version 1.0.0")
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
                    customVocabulary = transcription.vocabulary.joined(separator: ", ")
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

#Preview {
    SettingsPage()
}
