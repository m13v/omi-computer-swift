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

            // Sign in with Apple button
            VStack(spacing: 16) {
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
                .overlay {
                    if authState.isLoading {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.8))
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    }
                }

                if let error = authState.error {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
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
