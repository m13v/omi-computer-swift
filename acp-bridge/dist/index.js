/**
 * ACP Bridge — translates between OMI's JSON-lines protocol and the
 * Agent Client Protocol (ACP) used by claude-code-acp.
 *
 * Flow:
 * 1. Start omi-tools HTTP MCP server
 * 2. Spawn claude-code-acp as subprocess (JSON-RPC over stdio)
 * 3. Initialize ACP connection
 * 4. Handle auth if required (forward to Swift, wait for user action)
 * 5. On query: create session, send prompt, translate notifications → JSON-lines
 * 6. On interrupt: cancel the session
 */
import { spawn } from "child_process";
import { createInterface } from "readline";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { startOmiToolsServer, resolveToolCall, setQueryMode, } from "./omi-tools-http.js";
const __dirname = dirname(fileURLToPath(import.meta.url));
// Resolve path to bundled playwright MCP CLI
const playwrightCli = join(__dirname, "..", "node_modules", "@playwright", "mcp", "cli.js");
// --- Helpers ---
function send(msg) {
    try {
        process.stdout.write(JSON.stringify(msg) + "\n");
    }
    catch (err) {
        logErr(`Failed to write to stdout: ${err}`);
    }
}
function logErr(msg) {
    process.stderr.write(`[acp-bridge] ${msg}\n`);
}
// --- ACP subprocess management ---
let acpProcess = null;
let acpStdinWriter = null;
let acpResponseHandlers = new Map();
let acpNotificationHandler = null;
let nextRpcId = 1;
/** Send a JSON-RPC request to the ACP subprocess and wait for the response */
async function acpRequest(method, params = {}) {
    const id = nextRpcId++;
    const msg = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolve, reject) => {
        acpResponseHandlers.set(id, { resolve, reject });
        if (acpStdinWriter) {
            acpStdinWriter(msg);
        }
        else {
            reject(new Error("ACP process stdin not available"));
        }
    });
}
/** Send a JSON-RPC notification (no response expected) to ACP */
function acpNotify(method, params = {}) {
    const msg = JSON.stringify({ jsonrpc: "2.0", method, params });
    if (acpStdinWriter) {
        acpStdinWriter(msg);
    }
}
/** Start the ACP subprocess */
function startAcpProcess() {
    // Build environment — strip ANTHROPIC_API_KEY so ACP uses its own OAuth
    const env = { ...process.env };
    delete env.ANTHROPIC_API_KEY;
    delete env.CLAUDE_CODE_USE_VERTEX;
    env.NODE_NO_WARNINGS = "1";
    // The ACP binary communicates via JSON-RPC over stdio
    const acpBinary = join(__dirname, "..", "node_modules", ".bin", "claude-code-acp");
    logErr(`Starting ACP subprocess: ${acpBinary}`);
    acpProcess = spawn(acpBinary, [], {
        env,
        stdio: ["pipe", "pipe", "pipe"],
    });
    if (!acpProcess.stdin || !acpProcess.stdout || !acpProcess.stderr) {
        throw new Error("Failed to create ACP subprocess pipes");
    }
    // Write to ACP stdin
    acpStdinWriter = (line) => {
        try {
            acpProcess?.stdin?.write(line + "\n");
        }
        catch (err) {
            logErr(`Failed to write to ACP stdin: ${err}`);
        }
    };
    // Read ACP stdout (JSON-RPC responses and notifications)
    const rl = createInterface({
        input: acpProcess.stdout,
        terminal: false,
    });
    rl.on("line", (line) => {
        if (!line.trim())
            return;
        try {
            const msg = JSON.parse(line);
            if ("id" in msg && msg.id !== null && msg.id !== undefined) {
                // JSON-RPC response
                const id = msg.id;
                const handler = acpResponseHandlers.get(id);
                if (handler) {
                    acpResponseHandlers.delete(id);
                    if ("error" in msg) {
                        const err = msg.error;
                        const error = new AcpError(err.message, err.code, err.data);
                        handler.reject(error);
                    }
                    else {
                        handler.resolve(msg.result);
                    }
                }
            }
            else if ("method" in msg) {
                // JSON-RPC notification
                if (acpNotificationHandler) {
                    acpNotificationHandler(msg.method, msg.params);
                }
            }
        }
        catch (err) {
            logErr(`Failed to parse ACP message: ${line.slice(0, 200)}`);
        }
    });
    // Read ACP stderr for logging
    acpProcess.stderr.on("data", (data) => {
        const text = data.toString().trim();
        if (text) {
            logErr(`ACP stderr: ${text}`);
        }
    });
    acpProcess.on("exit", (code) => {
        logErr(`ACP process exited with code ${code}`);
        acpProcess = null;
        acpStdinWriter = null;
        // Reject any pending requests
        for (const [id, handler] of acpResponseHandlers) {
            handler.reject(new Error(`ACP process exited (code ${code})`));
        }
        acpResponseHandlers.clear();
    });
}
class AcpError extends Error {
    code;
    data;
    constructor(message, code, data) {
        super(message);
        this.code = code;
        this.data = data;
    }
}
// --- State ---
let omiToolsUrl = "";
let sessionId = "";
let activeAbort = null;
let interruptRequested = false;
let isInitialized = false;
let authMethods = [];
let authResolve = null;
// --- ACP initialization ---
async function initializeAcp() {
    if (isInitialized)
        return;
    try {
        // Build client capabilities
        const capabilities = {};
        // Playwright extension support
        const playwrightArgs = [playwrightCli];
        if (process.env.PLAYWRIGHT_USE_EXTENSION === "true") {
            playwrightArgs.push("--extension");
        }
        const result = (await acpRequest("initialize", {
            protocolVersion: 1,
            clientCapabilities: capabilities,
            clientInfo: {
                name: "omi-desktop",
                title: "Omi Desktop",
                version: "1.0.0",
            },
        }));
        logErr(`ACP initialized: protocol=${result.protocolVersion}, agent=${JSON.stringify(result.agentInfo)}`);
        // Check for auth methods
        if (result.authMethods && result.authMethods.length > 0) {
            authMethods = result.authMethods.map((m, i) => ({
                id: `auth-${i}`,
                type: m.type,
                displayName: m.type === "agent_auth" ? "Sign in with Claude" : m.type,
                args: m.args,
                env: m.env,
            }));
            logErr(`Auth methods available: ${authMethods.map((m) => m.type).join(", ")}`);
        }
        // Send initialized notification
        acpNotify("notifications/initialized");
        isInitialized = true;
    }
    catch (err) {
        if (err instanceof AcpError && err.code === -32000) {
            // AUTH_REQUIRED — extract auth methods from error data
            const data = err.data;
            if (data?.authMethods) {
                authMethods = data.authMethods.map((m, i) => ({
                    id: `auth-${i}`,
                    type: m.type,
                    displayName: m.type === "agent_auth" ? "Sign in with Claude" : m.type,
                    args: m.args,
                    env: m.env,
                }));
            }
            logErr(`ACP requires authentication: ${JSON.stringify(authMethods)}`);
            send({ type: "auth_required", methods: authMethods });
            // Wait for authenticate message from Swift
            await new Promise((resolve) => {
                authResolve = resolve;
            });
            // Retry initialization after auth
            isInitialized = false;
            await initializeAcp();
            return;
        }
        throw err;
    }
}
// --- Handle query from Swift ---
async function handleQuery(msg) {
    // Cancel any prior query
    if (activeAbort) {
        activeAbort.abort();
        activeAbort = null;
    }
    const abortController = new AbortController();
    activeAbort = abortController;
    interruptRequested = false;
    let fullText = "";
    const pendingTools = [];
    try {
        const mode = msg.mode ?? "act";
        setQueryMode(mode);
        logErr(`Query mode: ${mode}`);
        // Ensure ACP is initialized
        await initializeAcp();
        // Build MCP servers array for session
        const mcpServers = [
            {
                type: "http",
                name: "omi-tools",
                url: omiToolsUrl,
                headers: [],
            },
        ];
        // Add Playwright MCP server as stdio transport
        const playwrightArgs = [playwrightCli];
        if (process.env.PLAYWRIGHT_USE_EXTENSION === "true") {
            playwrightArgs.push("--extension");
        }
        const playwrightEnv = [];
        if (process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN) {
            playwrightEnv.push({
                name: "PLAYWRIGHT_MCP_EXTENSION_TOKEN",
                value: process.env.PLAYWRIGHT_MCP_EXTENSION_TOKEN,
            });
        }
        mcpServers.push({
            name: "playwright",
            command: process.execPath,
            args: playwrightArgs,
            env: playwrightEnv,
        });
        // Create a new session for each query (stateless, like agent-bridge)
        const sessionResult = (await acpRequest("session/new", {
            cwd: msg.cwd || process.env.HOME || "/",
            mcpServers,
        }));
        sessionId = sessionResult.sessionId;
        logErr(`ACP session created: ${sessionId}`);
        // Build the prompt with system context
        // ACP doesn't have a separate systemPrompt field — prepend it to the user message
        const fullPrompt = msg.systemPrompt
            ? `<system>\n${msg.systemPrompt}\n</system>\n\n${msg.prompt}`
            : msg.prompt;
        // Set up notification handler for this query
        acpNotificationHandler = (method, params) => {
            if (abortController.signal.aborted)
                return;
            const p = params;
            if (method === "session/update") {
                handleSessionUpdate(p, pendingTools, (text) => {
                    fullText += text;
                });
            }
        };
        // Send the prompt
        try {
            const promptResult = (await acpRequest("session/prompt", {
                sessionId,
                prompt: [{ type: "text", text: fullPrompt }],
            }));
            logErr(`Prompt completed: stopReason=${promptResult.stopReason}`);
            // Mark any remaining pending tools as completed
            for (const name of pendingTools) {
                send({ type: "tool_activity", name, status: "completed" });
            }
            pendingTools.length = 0;
            // Estimate cost (ACP doesn't provide cost directly)
            const costUsd = 0;
            send({ type: "result", text: fullText, sessionId, costUsd });
        }
        catch (err) {
            if (abortController.signal.aborted) {
                if (interruptRequested) {
                    for (const name of pendingTools) {
                        send({ type: "tool_activity", name, status: "completed" });
                    }
                    pendingTools.length = 0;
                    logErr(`Query interrupted by user, sending partial result (${fullText.length} chars)`);
                    send({ type: "result", text: fullText, sessionId, costUsd: 0 });
                }
                else {
                    logErr("Query aborted (superseded by new query)");
                }
                return;
            }
            throw err;
        }
    }
    catch (err) {
        if (abortController.signal.aborted) {
            if (interruptRequested) {
                for (const name of pendingTools) {
                    send({ type: "tool_activity", name, status: "completed" });
                }
                pendingTools.length = 0;
                send({ type: "result", text: fullText, sessionId, costUsd: 0 });
            }
            return;
        }
        const errMsg = err instanceof Error ? err.message : String(err);
        logErr(`Query error: ${errMsg}`);
        send({ type: "error", message: errMsg });
    }
    finally {
        if (activeAbort === abortController) {
            activeAbort = null;
        }
        acpNotificationHandler = null;
    }
}
/** Translate ACP session/update notifications into our JSON-lines protocol */
function handleSessionUpdate(params, pendingTools, onText) {
    const update = params;
    const updateType = update.type ?? params.type;
    switch (updateType) {
        case "agent_message_chunk": {
            const text = update.text ?? "";
            if (text) {
                // If tools were pending, they're now complete
                if (pendingTools.length > 0) {
                    for (const name of pendingTools) {
                        send({ type: "tool_activity", name, status: "completed" });
                    }
                    pendingTools.length = 0;
                }
                onText(text);
                send({ type: "text_delta", text });
            }
            break;
        }
        case "tool_call": {
            const toolCallId = update.toolCallId ?? "";
            const title = update.title ?? "unknown";
            const kind = update.kind ?? "";
            const status = update.status ?? "pending";
            if (status === "pending" || status === "in_progress") {
                pendingTools.push(title);
                send({
                    type: "tool_activity",
                    name: title,
                    status: "started",
                    toolUseId: toolCallId,
                });
                logErr(`Tool started: ${title} (id=${toolCallId}, kind=${kind})`);
            }
            break;
        }
        case "tool_call_update": {
            const toolCallId = update.toolCallId ?? "";
            const status = update.status ?? "";
            const content = update.content ?? "";
            const title = update.title ?? "unknown";
            if (status === "completed" || status === "cancelled") {
                // Remove from pending
                const idx = pendingTools.indexOf(title);
                if (idx >= 0)
                    pendingTools.splice(idx, 1);
                send({
                    type: "tool_activity",
                    name: title,
                    status: "completed",
                    toolUseId: toolCallId,
                });
                if (content) {
                    // Truncate to ~2000 chars for display
                    const truncated = content.length > 2000
                        ? content.slice(0, 2000) + "\n... (truncated)"
                        : content;
                    send({
                        type: "tool_result_display",
                        toolUseId: toolCallId,
                        name: title,
                        output: truncated,
                    });
                }
                logErr(`Tool completed: ${title} (id=${toolCallId}) output=${content ? content.length + " chars" : "none"}`);
            }
            break;
        }
        case "plan": {
            // Plan entries can be shown as thinking
            if (update.entries && Array.isArray(update.entries)) {
                for (const entry of update.entries) {
                    if (entry.content) {
                        send({ type: "thinking_delta", text: entry.content + "\n" });
                    }
                }
            }
            break;
        }
        default:
            logErr(`Unknown session update type: ${updateType}`);
    }
}
// --- Error handling ---
process.on("unhandledRejection", (reason) => {
    logErr(`Unhandled rejection: ${reason}`);
});
process.on("uncaughtException", (err) => {
    const code = err.code;
    if (code === "EPIPE" || code === "ERR_STREAM_DESTROYED") {
        logErr(`Caught ${code} in uncaughtException (subprocess pipe closed)`);
        return;
    }
    logErr(`Uncaught exception: ${err.message}\n${err.stack ?? ""}`);
    send({ type: "error", message: `Uncaught: ${err.message}` });
    process.exit(1);
});
process.stdout.on("error", (err) => {
    if (err.code === "EPIPE") {
        logErr("stdout pipe closed (parent process disconnected)");
        process.exit(0);
    }
    logErr(`stdout error: ${err.message}`);
});
// --- Main: read JSON lines from stdin ---
async function main() {
    // 1. Start omi-tools HTTP MCP server
    omiToolsUrl = await startOmiToolsServer();
    logErr(`omi-tools URL: ${omiToolsUrl}`);
    // 2. Start the ACP subprocess
    startAcpProcess();
    // 3. Signal readiness
    send({ type: "init", sessionId: "" });
    logErr("ACP Bridge started, waiting for queries...");
    // 4. Read JSON lines from Swift
    const rl = createInterface({ input: process.stdin, terminal: false });
    rl.on("line", (line) => {
        if (!line.trim())
            return;
        let msg;
        try {
            msg = JSON.parse(line);
        }
        catch {
            logErr(`Invalid JSON: ${line}`);
            return;
        }
        switch (msg.type) {
            case "query":
                handleQuery(msg).catch((err) => {
                    logErr(`Unhandled query error: ${err}`);
                    send({ type: "error", message: String(err) });
                });
                break;
            case "tool_result":
                resolveToolCall(msg);
                break;
            case "interrupt":
                logErr("Interrupt requested by user");
                interruptRequested = true;
                if (activeAbort)
                    activeAbort.abort();
                // Also cancel the ACP session
                if (sessionId) {
                    acpNotify("session/cancel", { sessionId });
                }
                break;
            case "authenticate": {
                logErr(`Authentication method selected: ${msg.methodId}`);
                // For agent_auth (the primary case), the ACP process handles it
                // We just need to signal that auth was completed
                // In practice, the ACP subprocess manages its own OAuth
                if (authResolve) {
                    authResolve();
                    authResolve = null;
                }
                send({ type: "auth_success" });
                break;
            }
            case "stop":
                logErr("Received stop signal, exiting");
                if (activeAbort)
                    activeAbort.abort();
                if (acpProcess) {
                    acpProcess.kill();
                }
                process.exit(0);
                break;
            default:
                logErr(`Unknown message type: ${msg.type}`);
        }
    });
    rl.on("close", () => {
        logErr("stdin closed, exiting");
        if (activeAbort)
            activeAbort.abort();
        if (acpProcess)
            acpProcess.kill();
        process.exit(0);
    });
}
main().catch((err) => {
    logErr(`Fatal error: ${err}`);
    send({ type: "error", message: `Fatal: ${err}` });
    process.exit(1);
});
