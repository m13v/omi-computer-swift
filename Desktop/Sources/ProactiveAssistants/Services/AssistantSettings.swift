import Foundation

/// Manages shared settings for all Proactive Assistants stored in UserDefaults
@MainActor
class AssistantSettings {
    static let shared = AssistantSettings()

    // MARK: - UserDefaults Keys

    private let cooldownIntervalKey = "assistantsCooldownInterval"
    private let glowOverlayEnabledKey = "assistantsGlowOverlayEnabled"
    private let analysisDelayKey = "assistantsAnalysisDelay"
    private let screenAnalysisEnabledKey = "screenAnalysisEnabled"
    private let transcriptionEnabledKey = "transcriptionEnabled"

    // MARK: - Default Values

    private let defaultCooldownInterval = 10 // minutes
    private let defaultGlowOverlayEnabled = true
    private let defaultAnalysisDelay = 60 // seconds (1 minute)
    private let defaultScreenAnalysisEnabled = true
    private let defaultTranscriptionEnabled = true

    private init() {
        // Register defaults
        UserDefaults.standard.register(defaults: [
            cooldownIntervalKey: defaultCooldownInterval,
            glowOverlayEnabledKey: defaultGlowOverlayEnabled,
            analysisDelayKey: defaultAnalysisDelay,
            screenAnalysisEnabledKey: defaultScreenAnalysisEnabled,
            transcriptionEnabledKey: defaultTranscriptionEnabled,
        ])
    }

    // MARK: - Properties

    /// Cooldown interval between notifications in minutes
    var cooldownInterval: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: cooldownIntervalKey)
            return value > 0 ? value : defaultCooldownInterval
        }
        set {
            UserDefaults.standard.set(newValue, forKey: cooldownIntervalKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Cooldown interval in seconds (for NotificationService)
    var cooldownIntervalSeconds: TimeInterval {
        return TimeInterval(cooldownInterval * 60)
    }

    /// Whether the glow overlay effect is enabled
    var glowOverlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: glowOverlayEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: glowOverlayEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Delay in seconds before analyzing after an app switch (0 = instant, 60 = 1 min, 300 = 5 min)
    var analysisDelay: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: analysisDelayKey)
            return value >= 0 ? value : defaultAnalysisDelay
        }
        set {
            UserDefaults.standard.set(newValue, forKey: analysisDelayKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether screen analysis (proactive monitoring) should be enabled
    var screenAnalysisEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: screenAnalysisEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: screenAnalysisEnabledKey)
            NotificationCenter.default.post(name: .assistantSettingsDidChange, object: nil)
        }
    }

    /// Whether transcription should be enabled
    var transcriptionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: transcriptionEnabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: transcriptionEnabledKey)
            NotificationCenter.default.post(name: .transcriptionSettingsDidChange, object: nil)
        }
    }

    /// Reset all settings to defaults
    func resetToDefaults() {
        cooldownInterval = defaultCooldownInterval
        glowOverlayEnabled = defaultGlowOverlayEnabled
        analysisDelay = defaultAnalysisDelay
        screenAnalysisEnabled = defaultScreenAnalysisEnabled
        transcriptionEnabled = defaultTranscriptionEnabled
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let assistantSettingsDidChange = Notification.Name("assistantSettingsDidChange")
    static let assistantMonitoringStateDidChange = Notification.Name("assistantMonitoringStateDidChange")
    static let assistantMonitoringToggleRequested = Notification.Name("assistantMonitoringToggleRequested")
    static let transcriptionSettingsDidChange = Notification.Name("transcriptionSettingsDidChange")
}

// MARK: - Backward Compatibility

/// Alias for backward compatibility
typealias FocusSettings = AssistantSettings

extension Notification.Name {
    static let focusSettingsDidChange = Notification.Name.assistantSettingsDidChange
    static let focusMonitoringStateDidChange = Notification.Name.assistantMonitoringStateDidChange
}
