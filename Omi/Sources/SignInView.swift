import SwiftUI

struct SignInView: View {
    @ObservedObject var authState: AuthState

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Logo/Title
            VStack(spacing: 16) {
                Text("OMI")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.white)

                Text("Sign in to continue")
                    .font(.title3)
                    .foregroundColor(.gray)
            }

            Spacer()

            // Sign in buttons
            VStack(spacing: 12) {
                // Sign in with Apple
                Button(action: {
                    Task {
                        do {
                            try await AuthService.shared.signInWithApple()
                        } catch {
                            let errorMsg = "Error: \(error.localizedDescription)"
                            authState.error = errorMsg
                            NSLog("OMI Sign in error: %@", errorMsg)
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo")
                            .font(.system(size: 18))
                        Text("Sign in with Apple")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(authState.isLoading)

                // Sign in with Google
                Button(action: {
                    Task {
                        do {
                            try await AuthService.shared.signInWithGoogle()
                        } catch {
                            let errorMsg = "Error: \(error.localizedDescription)"
                            authState.error = errorMsg
                            NSLog("OMI Sign in error: %@", errorMsg)
                        }
                    }
                }) {
                    HStack(spacing: 8) {
                        // Google "G" logo using SF Symbol or text
                        Text("G")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.blue, .green, .yellow, .red],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Text("Sign in with Google")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.white)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(authState.isLoading)

                // Loading overlay for both buttons
                if authState.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .padding(.top, 8)
                }

                if let error = authState.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40)

            Spacer()
                .frame(height: 60)
        }
        .frame(width: 400, height: 500)
        .background(Color.black.opacity(0.9))
    }
}

#Preview {
    SignInView(authState: AuthState.shared)
}
