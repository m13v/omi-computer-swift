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
import { createServer } from "http";
import { randomBytes, createHash } from "crypto";
import { execSync } from "child_process";
import { URL } from "url";
import { userInfo } from "os";
// --- Constants (from Claude Code CLI) ---
const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const TOKEN_URL = "https://console.anthropic.com/v1/oauth/token";
const SUCCESS_URL = "https://console.anthropic.com/oauth/code/success?app=claude-code";
const SCOPES = "user:inference";
const KEYCHAIN_SERVICE = "Claude Code-credentials";
const TOKEN_EXPIRY_SECONDS = 31536000; // 1 year
// --- PKCE Helpers ---
function base64url(buf) {
    return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
function generateCodeVerifier() {
    return base64url(randomBytes(32));
}
function generateCodeChallenge(verifier) {
    return base64url(createHash("sha256").update(verifier).digest());
}
function generateState() {
    return base64url(randomBytes(32));
}
/**
 * Start the OAuth flow. Returns the auth URL to open in the browser
 * and a promise that resolves when authentication completes.
 */
export async function startOAuthFlow(logErr) {
    const codeVerifier = generateCodeVerifier();
    const codeChallenge = generateCodeChallenge(codeVerifier);
    const state = generateState();
    // Start local callback server on a random port
    const { server, port } = await startCallbackServer();
    logErr(`OAuth callback server listening on port ${port}`);
    const redirectUri = `http://localhost:${port}/callback`;
    // Build authorization URL
    const authUrl = new URL(AUTHORIZE_URL);
    authUrl.searchParams.set("code", "true");
    authUrl.searchParams.set("client_id", CLIENT_ID);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("scope", SCOPES);
    authUrl.searchParams.set("code_challenge", codeChallenge);
    authUrl.searchParams.set("code_challenge_method", "S256");
    authUrl.searchParams.set("state", state);
    let cancelled = false;
    let cancelReject = null;
    const complete = new Promise((resolve, reject) => {
        cancelReject = reject;
        // Wait for the callback
        waitForCallback(server, state, logErr)
            .then(async (code) => {
            if (cancelled)
                return;
            logErr("OAuth callback received, exchanging code for token...");
            // Exchange code for token
            const tokens = await exchangeCodeForToken(code, codeVerifier, state, redirectUri, logErr);
            // Store credentials in Keychain
            storeCredentials(tokens, logErr);
            resolve(tokens);
        })
            .catch((err) => {
            if (!cancelled)
                reject(err);
        })
            .finally(() => {
            server.close();
        });
    });
    return {
        authUrl: authUrl.toString(),
        complete,
        cancel: () => {
            cancelled = true;
            server.close();
            cancelReject?.(new Error("OAuth flow cancelled"));
        },
    };
}
// --- Callback Server ---
async function startCallbackServer() {
    return new Promise((resolve, reject) => {
        const server = createServer();
        server.once("error", reject);
        server.listen(0, "localhost", () => {
            const addr = server.address();
            if (!addr || typeof addr === "string") {
                reject(new Error("Failed to get server address"));
                return;
            }
            resolve({ server, port: addr.port });
        });
    });
}
function waitForCallback(server, expectedState, logErr) {
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            reject(new Error("OAuth callback timed out (10 minutes)"));
            server.close();
        }, 10 * 60 * 1000);
        server.on("request", (req, res) => {
            const parsed = new URL(req.url || "", `http://localhost`);
            if (parsed.pathname !== "/callback") {
                res.writeHead(404);
                res.end("Not Found");
                return;
            }
            const code = parsed.searchParams.get("code");
            const state = parsed.searchParams.get("state");
            if (!code) {
                res.writeHead(400);
                res.end("Authorization code not found");
                reject(new Error("No authorization code received"));
                clearTimeout(timeout);
                return;
            }
            if (state !== expectedState) {
                res.writeHead(400);
                res.end("Invalid state parameter");
                reject(new Error("Invalid state parameter"));
                clearTimeout(timeout);
                return;
            }
            logErr("OAuth callback received with valid code");
            // Redirect browser to success page
            res.writeHead(302, { Location: SUCCESS_URL });
            res.end();
            clearTimeout(timeout);
            resolve(code);
        });
    });
}
// --- Token Exchange ---
async function exchangeCodeForToken(code, codeVerifier, state, redirectUri, logErr) {
    const body = {
        grant_type: "authorization_code",
        code,
        redirect_uri: redirectUri,
        client_id: CLIENT_ID,
        code_verifier: codeVerifier,
        state,
        expires_in: TOKEN_EXPIRY_SECONDS,
    };
    const response = await fetch(TOKEN_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(response.status === 401
            ? "Authentication failed: Invalid authorization code"
            : `Token exchange failed (${response.status}): ${text}`);
    }
    const data = (await response.json());
    logErr("Token exchange successful");
    const expiresAt = data.expires_in
        ? new Date(Date.now() + data.expires_in * 1000).toISOString()
        : undefined;
    return {
        accessToken: data.access_token,
        refreshToken: data.refresh_token,
        expiresAt,
        scopes: (data.scope || SCOPES).split(" "),
    };
}
// --- Credential Storage (macOS Keychain) ---
function storeCredentials(tokens, logErr) {
    const username = process.env.USER || userInfo().username;
    const credentialData = {
        claudeAiOauth: {
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken || null,
            expiresAt: tokens.expiresAt || null,
            scopes: tokens.scopes,
        },
    };
    const jsonStr = JSON.stringify(credentialData);
    try {
        // Use -U flag to upsert (update if exists, add if not)
        execSync(`security add-generic-password -U -a "${username}" -s "${KEYCHAIN_SERVICE}" -w "${jsonStr.replace(/"/g, '\\"')}"`, { stdio: "pipe" });
        logErr("Credentials stored in macOS Keychain");
    }
    catch (err) {
        logErr(`Failed to store in Keychain: ${err}, trying delete+add`);
        try {
            try {
                execSync(`security delete-generic-password -a "${username}" -s "${KEYCHAIN_SERVICE}"`, {
                    stdio: "pipe",
                });
            }
            catch {
                // ignore if not found
            }
            execSync(`security add-generic-password -a "${username}" -s "${KEYCHAIN_SERVICE}" -w "${jsonStr.replace(/"/g, '\\"')}"`, { stdio: "pipe" });
            logErr("Credentials stored in macOS Keychain (after delete+add)");
        }
        catch (err2) {
            logErr(`Failed to store credentials: ${err2}`);
        }
    }
}
