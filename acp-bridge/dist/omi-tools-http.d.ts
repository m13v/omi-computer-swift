/**
 * HTTP-based MCP server that exposes omi tools (execute_sql, semantic_search)
 * to the ACP agent. Tool calls are forwarded to Swift via stdout using the
 * same protocol as agent-bridge.
 *
 * This replaces the Agent SDK's createSdkMcpServer() with a standalone HTTP
 * server that ACP can connect to via its HTTP MCP transport.
 */
import type { ToolResultMessage } from "./protocol.js";
export declare function setQueryMode(mode: "ask" | "act"): void;
/** Resolve a pending tool call with a result from Swift */
export declare function resolveToolCall(msg: ToolResultMessage): void;
/**
 * Start the HTTP MCP server on a random localhost port.
 * Returns the URL to connect to.
 */
export declare function startOmiToolsServer(): Promise<string>;
