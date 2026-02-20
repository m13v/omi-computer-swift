/**
 * Stdio-based MCP server for omi tools (execute_sql, semantic_search).
 * This script is spawned as a subprocess by the ACP agent.
 * It reads JSON-RPC requests from stdin and writes responses to stdout.
 *
 * Tool calls are forwarded to the parent acp-bridge process via a named pipe
 * (passed as OMI_BRIDGE_PIPE env var), which then forwards them to Swift.
 */
export {};
