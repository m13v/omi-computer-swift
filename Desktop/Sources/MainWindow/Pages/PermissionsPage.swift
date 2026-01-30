import SwiftUI
import AppKit
import AVFoundation

struct PermissionsPage: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(OmiColors.warning)

                        Text("Permissions Required")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(OmiColors.textPrimary)
                    }

                    Text("Omi needs the following permissions to work properly.")
                        .font(.system(size: 14))
                        .foregroundColor(OmiColors.textSecondary)
                }
                .padding(.bottom, 8)

                // Permission sections
                VStack(spacing: 20) {
                    // Microphone Permission
                    MicrophonePermissionSection(appState: appState)

                    // Screen Recording Permission
                    ScreenRecordingPermissionSection(appState: appState)
                }

                // All permissions granted message
                if !appState.hasMissingPermissions {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)

                        Text("All permissions granted! Omi is ready to use.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(OmiColors.textPrimary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.green.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.green.opacity(0.3), lineWidth: 1)
                            )
                    )
                }

                Spacer()
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            appState.checkAllPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Auto-refresh when app becomes active (user may have granted permission in System Settings)
            appState.checkAllPermissions()
        }
    }
}

// MARK: - Microphone Permission Section
struct MicrophonePermissionSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 16) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(appState.hasMicrophonePermission ? Color.green.opacity(0.15) : OmiColors.backgroundTertiary)
                            .frame(width: 48, height: 48)

                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(appState.hasMicrophonePermission ? .green : OmiColors.textSecondary)
                    }

                    // Title and status
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Microphone")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(OmiColors.textPrimary)

                            statusBadge(isGranted: appState.hasMicrophonePermission)
                        }

                        Text("Required for voice recording and transcription")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .padding(20)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded && !appState.hasMicrophonePermission {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    Text("How to grant microphone access:")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        instructionStep(number: 1, text: "Click \"Grant Access\" below - a system dialog will appear")
                        instructionStep(number: 2, text: "Click \"OK\" to allow microphone access")
                        instructionStep(number: 3, text: "If no dialog appears, find \"Omi Computer\" in Settings and enable it")
                    }

                    Button(action: {
                        // Always try to request permission - this triggers the system dialog
                        // and makes the app appear in the list if not already there
                        Task {
                            let granted = await AVCaptureDevice.requestAccess(for: .audio)
                            await MainActor.run {
                                appState.hasMicrophonePermission = granted
                                if !granted {
                                    // If not granted, open System Settings so user can enable manually
                                    openMicrophoneSettings()
                                }
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "hand.tap.fill")
                                .font(.system(size: 14))
                            Text("Grant Access")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(OmiColors.purplePrimary)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(OmiColors.backgroundSecondary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(appState.hasMicrophonePermission ? Color.green.opacity(0.3) : OmiColors.backgroundQuaternary.opacity(0.5), lineWidth: 1)
                )
        )
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Screen Recording Permission Section
struct ScreenRecordingPermissionSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 16) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(appState.hasScreenRecordingPermission ? Color.green.opacity(0.15) : OmiColors.backgroundTertiary)
                            .frame(width: 48, height: 48)

                        Image(systemName: "rectangle.inset.filled.and.person.filled")
                            .font(.system(size: 22))
                            .foregroundColor(appState.hasScreenRecordingPermission ? .green : OmiColors.textSecondary)
                    }

                    // Title and status
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Screen Recording")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(OmiColors.textPrimary)

                            statusBadge(isGranted: appState.hasScreenRecordingPermission)
                        }

                        Text("Required for proactive monitoring and context awareness")
                            .font(.system(size: 13))
                            .foregroundColor(OmiColors.textTertiary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textTertiary)
                }
                .padding(20)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded && !appState.hasScreenRecordingPermission {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                        .background(OmiColors.backgroundQuaternary)

                    Text("How to grant screen recording access:")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(OmiColors.textPrimary)

                    VStack(alignment: .leading, spacing: 12) {
                        instructionStep(number: 1, text: "Click \"Open Settings\" below - this will make Omi appear in the list")
                        instructionStep(number: 2, text: "Find \"Omi Computer\" in the Screen Recording list")
                        instructionStep(number: 3, text: "Toggle the switch to enable screen recording")
                        instructionStep(number: 4, text: "Return to Omi - permission will update automatically")
                    }

                    // Tutorial GIF
                    AnimatedGIFView(gifName: "permissions")
                        .frame(maxWidth: 400, maxHeight: 300)
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(OmiColors.backgroundQuaternary, lineWidth: 1)
                        )

                    Button(action: {
                        // First trigger screen capture to make app appear in list
                        appState.triggerScreenRecordingPermission()
                        // Then open System Settings after a brief delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            ProactiveAssistantsPlugin.shared.openScreenRecordingPreferences()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "gear")
                                .font(.system(size: 14))
                            Text("Open Settings")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(OmiColors.purplePrimary)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(OmiColors.backgroundSecondary.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(appState.hasScreenRecordingPermission ? Color.green.opacity(0.3) : OmiColors.backgroundQuaternary.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - Helper Views

private func statusBadge(isGranted: Bool) -> some View {
    HStack(spacing: 4) {
        Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.system(size: 12))
        Text(isGranted ? "Granted" : "Not Granted")
            .font(.system(size: 12, weight: .medium))
    }
    .foregroundColor(isGranted ? .green : OmiColors.warning)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
        Capsule()
            .fill(isGranted ? Color.green.opacity(0.15) : OmiColors.warning.opacity(0.15))
    )
}

private func instructionStep(number: Int, text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Text("\(number)")
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(OmiColors.purplePrimary))

        Text(text)
            .font(.system(size: 13))
            .foregroundColor(OmiColors.textSecondary)
    }
}

#Preview {
    PermissionsPage(appState: AppState())
        .frame(width: 800, height: 700)
        .background(OmiColors.backgroundPrimary)
}
