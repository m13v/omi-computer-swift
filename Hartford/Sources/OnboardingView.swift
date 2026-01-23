import SwiftUI

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @AppStorage("onboardingStep") private var currentStep = 0
    @Environment(\.dismiss) private var dismiss

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
    }

    private var onboardingContent: some View {
        VStack(spacing: 24) {
            // Progress indicators with checkmarks for completed steps
            HStack(spacing: 12) {
                ForEach(0..<steps.count, id: \.self) { index in
                    if index < currentStep {
                        // Completed step - show checkmark
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                    } else if index == currentStep {
                        // Current step - filled circle
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
            }
            .padding(.top, 20)

            Spacer()

            // Step content
            stepContent

            Spacer()

            // Continue button
            Button(action: handleContinue) {
                Text(buttonTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
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
                icon: "bell.badge",
                title: "Notifications",
                description: "OMI sends you gentle notifications when it detects you're getting distracted from your work."
            )
        case 2:
            stepView(
                icon: "gearshape.2",
                title: "Automation",
                description: "OMI needs Automation permission to detect which app you're using.\n\nClick below to open System Settings, then enable OMI under Automation."
            )
        case 3:
            stepView(
                icon: "rectangle.dashed.badge.record",
                title: "Screen Recording",
                description: "OMI needs Screen Recording permission to capture your screen and analyze your focus.\n\nClick below to open System Settings, then enable OMI."
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

    private func stepView(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

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

    private var buttonTitle: String {
        switch currentStep {
        case 0:
            return "Continue"
        case 1:
            return "Enable Notifications"
        case 2:
            return "Open Automation Settings"
        case 3:
            return "Open Screen Recording Settings"
        case 4:
            return "Get Started"
        default:
            return "Continue"
        }
    }

    private func handleContinue() {
        switch currentStep {
        case 0:
            currentStep += 1
        case 1:
            appState.requestNotificationPermission()
            currentStep += 1
        case 2:
            // Trigger automation permission prompt then open settings
            appState.triggerAutomationPermission()
            currentStep += 1
        case 3:
            // Trigger screen recording permission prompt then open settings
            appState.triggerScreenRecordingPermission()
            currentStep += 1
        case 4:
            appState.hasCompletedOnboarding = true
            dismiss()
        default:
            break
        }
    }
}
