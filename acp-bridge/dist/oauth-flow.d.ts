/**
 * Standalone OAuth flow for Claude authentication.
 * Reimplements the `setup-token` flow from Claude Code CLI
 * without requiring Ink/TTY.
 *
 * Flow:
 * 1. Generate PKCE (code_verifier + code_challenge)
 * 2. Start local HTTP callback server
 * 3. Build authorize URL → caller opens in browser
 * 4. Wait for callback with auth code
 * 5. Exchange code for tokens
 * 6. Store credentials in macOS Keychain
 * 7. Redirect browser to success page
 */
export interface OAuthResult {
    accessToken: string;
    refreshToken?: string;
    expiresAt?: string;
    scopes: string[];
}
export interface OAuthFlowHandle {
    /** URL to open in the browser */
    authUrl: string;
    /** Resolves when OAuth completes (code exchanged, credentials stored) */
    complete: Promise<OAuthResult>;
    /** Cancel the flow (close server, reject promise) */
    cancel: () => void;
}
/**
 * Start the OAuth flow. Returns the auth URL to open in the browser
 * and a promise that resolves when authentication completes.
 */
export declare function startOAuthFlow(logErr: (msg: string) => void): Promise<OAuthFlowHandle>;
