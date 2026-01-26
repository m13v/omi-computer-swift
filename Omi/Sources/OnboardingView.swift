import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @AppStorage("onboardingStep") private var currentStep = 0
    @Environment(\.dismiss) private var dismiss

    // Track which permissions user has attempted to grant (to start polling)
    // Persisted so polling resumes after app restart
    @AppStorage("hasTriggeredNotification") private var hasTriggeredNotification = false
    @AppStorage("hasTriggeredAutomation") private var hasTriggeredAutomation = false
    @AppStorage("hasTriggeredScreenRecording") private var hasTriggeredScreenRecording = false
    @AppStorage("hasTriggeredMicrophone") private var hasTriggeredMicrophone = false
    @AppStorage("hasTriggeredSystemAudio") private var hasTriggeredSystemAudio = false

    // Timer to periodically check permission status (only for triggered permissions)
    let permissionCheckTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    let steps = ["Welcome", "Name", "Notifications", "Automation", "Screen Recording", "Microphone", "System Audio", "Done"]

    // State for name input
    @State private var nameInput: String = ""
    @State private var nameError: String = ""
    @FocusState private var isNameFieldFocused: Bool

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                // Auto-start monitoring and dismiss
                Color.clear
                    .onAppear {
                        if !appState.isMonitoring {
                            appState.startMonitoring()
                        }
                        dismiss()
                    }
            } else {
                onboardingContent
            }
        }
        .frame(
            width: currentStep == 4 && !appState.hasScreenRecordingPermission ? 500 : 400,
            height: currentStep == 4 && !appState.hasScreenRecordingPermission ? 520 : 400
        )
        .onReceive(permissionCheckTimer) { _ in
            // Only poll for permissions that user has triggered
            if hasTriggeredNotification {
                appState.checkNotificationPermission()
            }
            if hasTriggeredAutomation {
                appState.checkAutomationPermission()
            }
            if hasTriggeredScreenRecording {
                appState.checkScreenRecordingPermission()
            }
            if hasTriggeredMicrophone {
                appState.checkMicrophonePermission()
            }
            if hasTriggeredSystemAudio {
                appState.checkSystemAudioPermission()
            }
        }
        // Bring app to front when permissions are granted
        .onChange(of: appState.hasNotificationPermission) { _, granted in
            if granted {
                log("Notification permission granted, bringing to front")
                bringToFront()
            }
        }
        .onChange(of: appState.hasAutomationPermission) { _, granted in
            if granted {
                log("Automation permission granted, bringing to front")
                bringToFront()
            }
        }
        .onChange(of: appState.hasScreenRecordingPermission) { _, granted in
            if granted {
                log("Screen recording permission granted, bringing to front")
                bringToFront()
            }
        }
        .onChange(of: appState.hasMicrophonePermission) { _, granted in
            if granted {
                log("Microphone permission granted, bringing to front")
                bringToFront()
            }
        }
        .onChange(of: appState.hasSystemAudioPermission) { _, granted in
            if granted {
                log("System audio permission granted, bringing to front")
                bringToFront()
            }
        }
    }

    private func bringToFront() {
        log("bringToFront() called, scheduling activation in 0.3s")
        log("Current app is active: \(NSApp.isActive ? "YES" : "NO")")

        // Small delay to let window ordering settle after System Preferences closes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log("Executing activation after delay")

            // Use NSApp.activate which works even when app is not active
            NSApp.activate(ignoringOtherApps: true)
            log("Called NSApp.activate(ignoringOtherApps: true)")

            // Also bring the onboarding window to front
            var foundWindow = false
            for window in NSApp.windows {
                if window.title == "Welcome to OMI-COMPUTER" {
                    foundWindow = true
                    log("Found 'Welcome to OMI-COMPUTER' window, making key and ordering front")
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
            }
            if !foundWindow {
                log("WARNING - Could not find 'Welcome to OMI-COMPUTER' window!")
            }

            log("After activation - app is active: \(NSApp.isActive ? "YES" : "NO")")
        }
    }

    /// Check if current step's permission is granted
    private var currentPermissionGranted: Bool {
        switch currentStep {
        case 1: return !nameInput.trimmingCharacters(in: .whitespaces).isEmpty // Name step - valid if name entered
        case 2: return appState.hasNotificationPermission
        case 3: return appState.hasAutomationPermission
        case 4: return appState.hasScreenRecordingPermission
        case 5: return appState.hasMicrophonePermission
        case 6: return !appState.isSystemAudioSupported || appState.hasSystemAudioPermission // Skip if not supported
        default: return true
        }
    }

    private var onboardingContent: some View {
        VStack(spacing: 24) {
            // Progress indicators with checkmarks for granted permissions
            HStack(spacing: 12) {
                ForEach(0..<steps.count, id: \.self) { index in
                    progressIndicator(for: index)
                }
            }
            .padding(.top, 20)

            Spacer()

            // Step content
            stepContent

            Spacer()

            // Buttons
            buttonSection
        }
    }

    @ViewBuilder
    private func progressIndicator(for index: Int) -> some View {
        let isGranted = permissionGranted(for: index)

        if index < currentStep || (index == currentStep && isGranted) {
            // Completed or granted - show checkmark
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
        } else if index == currentStep {
            // Current step, not yet granted - filled circle
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
        } else {
            // Future step - empty circle
            Circle()
                .stroke(Color.gray.opacity(0.3), lineWidth: 1.5)
                .frame(width: 10, height: 10)
        }
    }

    private func permissionGranted(for step: Int) -> Bool {
        switch step {
        case 0: return true // Welcome - always "granted"
        case 1: return !nameInput.trimmingCharacters(in: .whitespaces).isEmpty // Name step
        case 2: return appState.hasNotificationPermission
        case 3: return appState.hasAutomationPermission
        case 4: return appState.hasScreenRecordingPermission
        case 5: return appState.hasMicrophonePermission
        case 6: return !appState.isSystemAudioSupported || appState.hasSystemAudioPermission // System Audio
        case 7: return true // Done - always "granted"
        default: return false
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0:
            stepView(
                icon: "brain.head.profile",
                title: "Welcome to OMI",
                description: "OMI helps you stay focused by monitoring your screen and alerting you when you get distracted.\n\nLet's set up a few permissions to get started."
            )
        case 1:
            nameStepView
        case 2:
            stepView(
                icon: appState.hasNotificationPermission ? "checkmark.circle.fill" : "bell.badge",
                iconColor: appState.hasNotificationPermission ? .green : .accentColor,
                title: "Notifications",
                description: appState.hasNotificationPermission
                    ? "Notifications are enabled! You'll receive focus alerts from OMI."
                    : "OMI sends you gentle notifications when it detects you're getting distracted from your work."
            )
        case 3:
            stepView(
                icon: appState.hasAutomationPermission ? "checkmark.circle.fill" : "gearshape.2",
                iconColor: appState.hasAutomationPermission ? .green : .accentColor,
                title: "Automation",
                description: appState.hasAutomationPermission
                    ? "Automation permission granted! OMI can now detect which app you're using."
                    : "OMI needs Automation permission to detect which app you're using.\n\nClick below to grant permission, then return to this window."
            )
        case 4:
            screenRecordingStepView
        case 5:
            stepView(
                icon: appState.hasMicrophonePermission ? "checkmark.circle.fill" : "mic",
                iconColor: appState.hasMicrophonePermission ? .green : .accentColor,
                title: "Microphone",
                description: appState.hasMicrophonePermission
                    ? "Microphone access granted! OMI can now transcribe your conversations."
                    : "OMI needs microphone access to transcribe your conversations and provide context-aware assistance."
            )
        case 6:
            systemAudioStepView
        case 7:
            stepView(
                icon: "checkmark.circle",
                title: "You're All Set!",
                description: "OMI is ready to help you stay focused.\n\nClick the OMI menu bar icon to start monitoring."
            )
        default:
            EmptyView()
        }
    }

    // MARK: - Name Step View

    private var nameStepView: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.circle")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("What's your name?")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Tell us how you'd like to be addressed.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Enter your name", text: $nameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .frame(maxWidth: 280)
                    .focused($isNameFieldFocused)
                    .onSubmit {
                        if isNameValid {
                            handleMainAction()
                        }
                    }

                if !nameError.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.caption)
                        Text(nameError)
                            .font(.caption)
                    }
                    .foregroundColor(.red)
                }

                if !nameInput.isEmpty {
                    Text("\(nameInput.count) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .onAppear {
            // Pre-fill from Firebase if available
            if nameInput.isEmpty {
                let existingName = AuthService.shared.displayName
                if !existingName.isEmpty {
                    nameInput = existingName
                }
            }
            // Focus the text field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isNameFieldFocused = true
            }
        }
    }

    private var isNameValid: Bool {
        let trimmed = nameInput.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2
    }

    private func stepView(icon: String, iconColor: Color = .accentColor, title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(iconColor)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttonSection: some View {
        HStack(spacing: 16) {
            // Back button (not shown on first step)
            if currentStep > 0 {
                Button(action: { currentStep -= 1 }) {
                    Text("Back")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Main action / Continue button
            Button(action: handleMainAction) {
                Text(mainButtonTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 20)
    }

    private var mainButtonTitle: String {
        switch currentStep {
        case 0:
            return "Get Started"
        case 1:
            return "Continue"
        case 2:
            return appState.hasNotificationPermission ? "Continue" : "Enable Notifications"
        case 3:
            return appState.hasAutomationPermission ? "Continue" : "Grant Automation Access"
        case 4:
            return appState.hasScreenRecordingPermission ? "Continue" : "Grant Screen Recording"
        case 5:
            return appState.hasMicrophonePermission ? "Continue" : "Enable Microphone"
        case 6:
            return systemAudioButtonTitle
        case 7:
            return "Start Using OMI"
        default:
            return "Continue"
        }
    }

    private var systemAudioButtonTitle: String {
        if !appState.isSystemAudioSupported {
            return "Continue"  // Not supported on this macOS version
        }
        return appState.hasSystemAudioPermission ? "Continue" : "Enable System Audio"
    }

    // MARK: - Screen Recording Step with Tutorial GIF

    private var screenRecordingStepView: some View {
        VStack(spacing: 12) {
            if appState.hasScreenRecordingPermission {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)

                Text("Screen Recording")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Screen Recording permission granted! OMI can now analyze your focus.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Screen Recording")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Follow these steps to grant permission:")
                    .font(.body)
                    .foregroundColor(.secondary)

                // Animated GIF tutorial
                AnimatedGIFView(gifName: "permissions")
                    .frame(maxWidth: 440, maxHeight: 350)
                    .cornerRadius(8)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
        }
    }

    // MARK: - System Audio Step View

    private var systemAudioStepView: some View {
        VStack(spacing: 16) {
            if !appState.isSystemAudioSupported {
                // macOS version doesn't support system audio capture
                Image(systemName: "speaker.slash")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text("System Audio")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("System audio capture requires macOS 14.4 or later.\n\nYou can still use OMI with microphone-only transcription.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else if appState.hasSystemAudioPermission {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)

                Text("System Audio")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("System audio capture is ready! OMI can now capture audio from your meetings and media.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("System Audio")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("OMI can capture system audio to transcribe meetings, videos, and other media playing on your Mac.\n\nThis uses the same Screen Recording permission you already granted.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleMainAction() {
        switch currentStep {
        case 0:
            MixpanelManager.shared.onboardingStepCompleted(step: 0, stepName: "Welcome")
            currentStep += 1
        case 1:
            // Name step - validate and save
            let trimmedName = nameInput.trimmingCharacters(in: .whitespaces)
            if trimmedName.count < 2 {
                nameError = "Please enter at least 2 characters"
                return
            }
            nameError = ""
            // Save the name
            Task {
                await AuthService.shared.updateGivenName(trimmedName)
            }
            MixpanelManager.shared.onboardingStepCompleted(step: 1, stepName: "Name")
            currentStep += 1
        case 2:
            if appState.hasNotificationPermission {
                // Permission already granted - send test notification anyway and advance
                NotificationService.shared.sendNotification(
                    title: "Notifications Enabled",
                    message: "You'll receive focus alerts from OMI.",
                    applyCooldown: false
                )
                MixpanelManager.shared.onboardingStepCompleted(step: 2, stepName: "Notifications")
                MixpanelManager.shared.permissionGranted(permission: "notifications")
                currentStep += 1
            } else {
                MixpanelManager.shared.permissionRequested(permission: "notifications")
                hasTriggeredNotification = true
                appState.requestNotificationPermission()
            }
        case 3:
            if appState.hasAutomationPermission {
                MixpanelManager.shared.onboardingStepCompleted(step: 3, stepName: "Automation")
                MixpanelManager.shared.permissionGranted(permission: "automation")
                currentStep += 1
            } else {
                MixpanelManager.shared.permissionRequested(permission: "automation")
                hasTriggeredAutomation = true
                appState.triggerAutomationPermission()
            }
        case 4:
            if appState.hasScreenRecordingPermission {
                MixpanelManager.shared.onboardingStepCompleted(step: 4, stepName: "Screen Recording")
                MixpanelManager.shared.permissionGranted(permission: "screen_recording")
                currentStep += 1
            } else {
                MixpanelManager.shared.permissionRequested(permission: "screen_recording")
                hasTriggeredScreenRecording = true
                appState.triggerScreenRecordingPermission()
            }
        case 5:
            if appState.hasMicrophonePermission {
                MixpanelManager.shared.onboardingStepCompleted(step: 5, stepName: "Microphone")
                MixpanelManager.shared.permissionGranted(permission: "microphone")
                currentStep += 1
            } else {
                MixpanelManager.shared.permissionRequested(permission: "microphone")
                hasTriggeredMicrophone = true
                appState.requestMicrophonePermission()
            }
        case 6:
            // System Audio step
            if !appState.isSystemAudioSupported {
                // Not supported on this macOS version - just continue
                MixpanelManager.shared.onboardingStepCompleted(step: 6, stepName: "System Audio")
                currentStep += 1
            } else if appState.hasSystemAudioPermission {
                MixpanelManager.shared.onboardingStepCompleted(step: 6, stepName: "System Audio")
                MixpanelManager.shared.permissionGranted(permission: "system_audio")
                currentStep += 1
            } else {
                MixpanelManager.shared.permissionRequested(permission: "system_audio")
                hasTriggeredSystemAudio = true
                appState.triggerSystemAudioPermission()
            }
        case 7:
            MixpanelManager.shared.onboardingStepCompleted(step: 7, stepName: "Done")
            MixpanelManager.shared.onboardingCompleted()
            appState.hasCompletedOnboarding = true
            appState.startMonitoring()
            appState.startTranscription()
            dismiss()
        default:
            break
        }
    }
}

// MARK: - Animated GIF View

struct AnimatedGIFView: NSViewRepresentable {
    let gifName: String

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.animates = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        if let url = Bundle.module.url(forResource: gifName, withExtension: "gif"),
           let image = NSImage(contentsOf: url) {
            imageView.image = image
        }

        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.animates = true
    }
}
