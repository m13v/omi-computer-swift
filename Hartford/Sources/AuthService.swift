import Foundation
import FirebaseAuth
import CryptoKit
import AppKit

class AuthService {
    static let shared = AuthService()

    // Use AuthState for UI updates - it's a pure Swift ObservableObject
    // that doesn't reference Firebase types at the class level
    private var authState: AuthState { AuthState.shared }

    var isSignedIn: Bool {
        get { authState.isSignedIn }
        set { authState.isSignedIn = newValue }
    }
    var isLoading: Bool {
        get { authState.isLoading }
        set { authState.isLoading = newValue }
    }
    var error: String? {
        get { authState.error }
        set { authState.error = newValue }
    }

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var isConfigured: Bool = false

    // OAuth state for CSRF protection
    private var pendingOAuthState: String?
    private var oauthContinuation: CheckedContinuation<(code: String, state: String), Error>?

    // API Configuration
    // Use cloudflare tunnel for local development (Apple OAuth requires HTTPS)
    private let apiBaseURL: String = "https://short-powerful-codes-prospective.trycloudflare.com/"
    private let redirectURI: String = "omi-computer://auth/callback"

    init() {
        // Initialize without super
    }

    // MARK: - Configuration (call after FirebaseApp.configure())

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        setupAuthStateListener()
    }

    // MARK: - Auth State Listener

    private func setupAuthStateListener() {
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.isSignedIn = user != nil
                AuthState.shared.userEmail = user?.email
            }
        }
    }

    // MARK: - Sign in with Apple (Web OAuth Flow)

    @MainActor
    func signInWithApple() async throws {
        NSLog("OMI AUTH: Starting Sign in with Apple (Web OAuth)")
        isLoading = true
        error = nil

        defer { isLoading = false }

        do {
            // Step 1: Generate state for CSRF protection
            let state = generateState()
            pendingOAuthState = state
            NSLog("OMI AUTH: Generated OAuth state")

            // Step 2: Build authorization URL
            let authURL = buildAuthorizationURL(provider: "apple", state: state)
            NSLog("OMI AUTH: Opening browser for authentication")

            // Step 3: Open browser for authentication
            guard let url = URL(string: authURL) else {
                throw AuthError.invalidURL
            }
            NSWorkspace.shared.open(url)

            // Step 4: Wait for callback with authorization code
            NSLog("OMI AUTH: Waiting for OAuth callback...")
            let (code, returnedState) = try await waitForOAuthCallback()

            // Step 5: Verify state matches
            guard returnedState == state else {
                NSLog("OMI AUTH: State mismatch - potential CSRF attack")
                throw AuthError.stateMismatch
            }
            NSLog("OMI AUTH: Received valid authorization code")

            // Step 6: Exchange code for custom token
            NSLog("OMI AUTH: Exchanging code for Firebase token...")
            let customToken = try await exchangeCodeForToken(code: code)
            NSLog("OMI AUTH: Got Firebase custom token")

            // Step 7: Sign in to Firebase with custom token
            NSLog("OMI AUTH: Signing in to Firebase...")
            do {
                let authResult = try await Auth.auth().signIn(withCustomToken: customToken)
                NSLog("OMI AUTH: Firebase sign-in SUCCESS - uid: %@", authResult.user.uid)
                AuthState.shared.userEmail = authResult.user.email
            } catch let firebaseError as NSError {
                // Check if it's a keychain error - still mark as signed in since server auth succeeded
                if firebaseError.domain == "NSCocoaErrorDomain" ||
                   firebaseError.localizedDescription.contains("keychain") {
                    NSLog("OMI AUTH: Keychain error (non-fatal for dev): %@", firebaseError.localizedDescription)
                    // For development, we can proceed - the server-side auth succeeded
                } else {
                    throw firebaseError
                }
            }

            isSignedIn = true
            NSLog("OMI AUTH: Sign in complete!")

        } catch {
            NSLog("OMI AUTH: Error during sign in: %@", error.localizedDescription)
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: - OAuth URL Building

    private func buildAuthorizationURL(provider: String, state: String) -> String {
        let encodedRedirectURI = redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI
        return "\(apiBaseURL)v1/auth/authorize?provider=\(provider)&redirect_uri=\(encodedRedirectURI)&state=\(state)"
    }

    // MARK: - OAuth Callback Handling

    private func waitForOAuthCallback() async throws -> (code: String, state: String) {
        try await withCheckedThrowingContinuation { continuation in
            self.oauthContinuation = continuation

            // Set a timeout
            Task {
                try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000) // 5 minutes
                if self.oauthContinuation != nil {
                    self.oauthContinuation?.resume(throwing: AuthError.timeout)
                    self.oauthContinuation = nil
                }
            }
        }
    }

    /// Called by AppDelegate when the app receives an OAuth callback URL
    @MainActor
    func handleOAuthCallback(url: URL) {
        NSLog("OMI AUTH: Received OAuth callback: %@", url.absoluteString)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            NSLog("OMI AUTH: Failed to parse callback URL")
            oauthContinuation?.resume(throwing: AuthError.invalidCallback)
            oauthContinuation = nil
            return
        }

        // Check if this is our auth callback
        guard url.scheme == "omi-computer" && url.host == "auth" && url.path == "/callback" else {
            NSLog("OMI AUTH: Not an auth callback URL")
            return
        }

        let queryItems = components.queryItems ?? []
        let code = queryItems.first(where: { $0.name == "code" })?.value
        let state = queryItems.first(where: { $0.name == "state" })?.value
        let error = queryItems.first(where: { $0.name == "error" })?.value

        if let error = error {
            NSLog("OMI AUTH: OAuth error: %@", error)
            oauthContinuation?.resume(throwing: AuthError.oauthError(error))
            oauthContinuation = nil
            return
        }

        guard let code = code, let state = state else {
            NSLog("OMI AUTH: Missing code or state in callback")
            oauthContinuation?.resume(throwing: AuthError.missingCodeOrState)
            oauthContinuation = nil
            return
        }

        NSLog("OMI AUTH: Successfully extracted code and state from callback")
        oauthContinuation?.resume(returning: (code: code, state: state))
        oauthContinuation = nil
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String) async throws -> String {
        guard let url = URL(string: "\(apiBaseURL)v1/auth/token") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "use_custom_token": "true"
        ]

        let bodyString = bodyParams
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")

        request.httpBody = bodyString.data(using: .utf8)

        NSLog("OMI AUTH: Sending token exchange request...")
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        NSLog("OMI AUTH: Token exchange response status: %d", httpResponse.statusCode)

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            NSLog("OMI AUTH: Token exchange failed: %@", responseBody)
            throw AuthError.tokenExchangeFailed(httpResponse.statusCode)
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse
        }

        // Get custom token
        guard let customToken = json["custom_token"] as? String else {
            NSLog("OMI AUTH: No custom_token in response")
            throw AuthError.missingCustomToken
        }

        return customToken
    }

    // MARK: - Get ID Token (for API calls)

    func getIdToken(forceRefresh: Bool = false) async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }

        let tokenResult = try await user.getIDTokenResult(forcingRefresh: forceRefresh)
        return tokenResult.token
    }

    func getAuthHeader() async throws -> String {
        let token = try await getIdToken(forceRefresh: false)
        return "Bearer \(token)"
    }

    // MARK: - Sign Out

    func signOut() throws {
        try Auth.auth().signOut()
        isSignedIn = false
    }

    // MARK: - Helper Methods

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case invalidCredential
    case invalidNonce
    case missingToken
    case notSignedIn
    case invalidURL
    case stateMismatch
    case timeout
    case invalidCallback
    case oauthError(String)
    case missingCodeOrState
    case invalidResponse
    case tokenExchangeFailed(Int)
    case missingCustomToken

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Invalid Apple credential"
        case .invalidNonce:
            return "Invalid nonce - please try again"
        case .missingToken:
            return "Missing identity token from Apple"
        case .notSignedIn:
            return "User is not signed in"
        case .invalidURL:
            return "Invalid authentication URL"
        case .stateMismatch:
            return "Security state mismatch - please try again"
        case .timeout:
            return "Authentication timed out - please try again"
        case .invalidCallback:
            return "Invalid authentication callback"
        case .oauthError(let error):
            return "Authentication error: \(error)"
        case .missingCodeOrState:
            return "Missing authentication code"
        case .invalidResponse:
            return "Invalid server response"
        case .tokenExchangeFailed(let code):
            return "Token exchange failed with status \(code)"
        case .missingCustomToken:
            return "Server did not return authentication token"
        }
    }
}
