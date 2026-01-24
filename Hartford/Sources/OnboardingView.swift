import SwiftUI

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

    let steps = ["Welcome", "Notifications", "Automation", "Screen Recording", "Done"]

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                // Empty view that dismisses immediately
                Color.clear
                    .onAppear { dismiss() }
            } else {
                onboardingContent
            }
        }
        .frame(width: 400, height: 400)
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
            stepView(
                icon: appState.hasScreenRecordingPermission ? "checkmark.circle.fill" : "rectangle.dashed.badge.record",
                iconColor: appState.hasScreenRecordingPermission ? .green : .accentColor,
                title: "Screen Recording",
                description: appState.hasScreenRecordingPermission
                    ? "Screen Recording permission granted! OMI can now analyze your focus."
                    : "OMI needs Screen Recording permission to capture your screen and analyze your focus.\n\nClick below to grant permission. You may need to restart the app."
            )
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
            dismiss()
        default:
            break
        }
    }
}
