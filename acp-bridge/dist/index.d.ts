/**
 * ACP Bridge — translates between OMI's JSON-lines protocol and the
 * Agent Client Protocol (ACP) used by claude-code-acp.
 *
 * Flow:
 * 1. Create Unix socket server for omi-tools relay
 * 2. Spawn claude-code-acp as subprocess (JSON-RPC over stdio)
 * 3. Initialize ACP connection
 * 4. Handle auth if required (forward to Swift, wait for user action)
 * 5. On query: create session, send prompt, translate notifications → JSON-lines
 * 6. On interrupt: cancel the session
 */
export {};
