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

    // Timer to periodically check permission status (only for triggered permissions)
    let permissionCheckTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    // Animation state for screen recording tutorial images
    @State private var currentTutorialImage = 0
    let tutorialImageTimer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    let steps = ["Welcome", "Notifications", "Automation", "Screen Recording", "Done"]

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
        .frame(width: 400, height: currentStep == 3 && !appState.hasScreenRecordingPermission ? 480 : 400)
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
        }
        // Bring app to front when permissions are granted
        .onChange(of: appState.hasNotificationPermission) { _, granted in
            if granted { bringToFront() }
        }
        .onChange(of: appState.hasAutomationPermission) { _, granted in
            if granted { bringToFront() }
        }
        .onChange(of: appState.hasScreenRecordingPermission) { _, granted in
            if granted { bringToFront() }
        }
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // Also bring the onboarding window to front
        for window in NSApp.windows {
            if window.title == "Welcome to OMI" {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    /// Check if current step's permission is granted
    private var currentPermissionGranted: Bool {
        switch currentStep {
        case 1: return appState.hasNotificationPermission
        case 2: return appState.hasAutomationPermission
        case 3: return appState.hasScreenRecordingPermission
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
        case 1: return appState.hasNotificationPermission
        case 2: return appState.hasAutomationPermission
        case 3: return appState.hasScreenRecordingPermission
        case 4: return true // Done - always "granted"
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
            stepView(
                icon: appState.hasNotificationPermission ? "checkmark.circle.fill" : "bell.badge",
                iconColor: appState.hasNotificationPermission ? .green : .accentColor,
                title: "Notifications",
                description: appState.hasNotificationPermission
                    ? "Notifications are enabled! You'll receive focus alerts from OMI."
                    : "OMI sends you gentle notifications when it detects you're getting distracted from your work."
            )
        case 2:
            stepView(
                icon: appState.hasAutomationPermission ? "checkmark.circle.fill" : "gearshape.2",
                iconColor: appState.hasAutomationPermission ? .green : .accentColor,
                title: "Automation",
                description: appState.hasAutomationPermission
                    ? "Automation permission granted! OMI can now detect which app you're using."
                    : "OMI needs Automation permission to detect which app you're using.\n\nClick below to grant permission, then return to this window."
            )
        case 3:
            screenRecordingStepView
        case 4:
            stepView(
                icon: "checkmark.circle",
                title: "You're All Set!",
                description: "OMI is ready to help you stay focused.\n\nClick the OMI menu bar icon to start monitoring."
            )
        default:
            EmptyView()
        }
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
            return appState.hasNotificationPermission ? "Continue" : "Enable Notifications"
        case 2:
            return appState.hasAutomationPermission ? "Continue" : "Grant Automation Access"
        case 3:
            return appState.hasScreenRecordingPermission ? "Continue" : "Grant Screen Recording"
        case 4:
            return "Start Using OMI"
        default:
            return "Continue"
        }
    }

    // MARK: - Screen Recording Step with Tutorial Images

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

                // Tutorial image slideshow
                ZStack {
                    ForEach(0..<3, id: \.self) { index in
                        tutorialImage(for: index)
                            .opacity(currentTutorialImage == index ? 1 : 0)
                            .animation(.easeInOut(duration: 0.5), value: currentTutorialImage)
                    }
                }
                .frame(height: 180)
                .onReceive(tutorialImageTimer) { _ in
                    if !appState.hasScreenRecordingPermission {
                        currentTutorialImage = (currentTutorialImage + 1) % 3
                    }
                }

                // Step indicator dots
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(currentTutorialImage == index ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .animation(.easeInOut(duration: 0.3), value: currentTutorialImage)
                    }
                }

                // Step labels
                Text(tutorialStepLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .animation(.easeInOut(duration: 0.3), value: currentTutorialImage)
            }
        }
    }

    private var tutorialStepLabel: String {
        switch currentTutorialImage {
        case 0: return "Step 1: Click \"Open System Settings\""
        case 1: return "Step 2: Toggle ON for OMI-COMPUTER"
        case 2: return "Step 3: Click \"Quit & Reopen\""
        default: return ""
        }
    }

    @ViewBuilder
    private func tutorialImage(for index: Int) -> some View {
        let imageName = "screen-recording-step\(index + 1)"
        if let url = Bundle.module.url(forResource: imageName, withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .overlay(Text("Image not found"))
        }
    }

    private func handleMainAction() {
        switch currentStep {
        case 0:
            currentStep += 1
        case 1:
            if appState.hasNotificationPermission {
                // Permission already granted - send test notification anyway and advance
                NotificationService.shared.sendNotification(
                    title: "Notifications Enabled",
                    message: "You'll receive focus alerts from OMI.",
                    applyCooldown: false
                )
                currentStep += 1
            } else {
                hasTriggeredNotification = true
                appState.requestNotificationPermission()
            }
        case 2:
            if appState.hasAutomationPermission {
                currentStep += 1
            } else {
                hasTriggeredAutomation = true
                appState.triggerAutomationPermission()
            }
        case 3:
            if appState.hasScreenRecordingPermission {
                currentStep += 1
            } else {
                hasTriggeredScreenRecording = true
                appState.triggerScreenRecordingPermission()
            }
        case 4:
            appState.hasCompletedOnboarding = true
            appState.startMonitoring()
            dismiss()
        default:
            break
        }
    }
}
