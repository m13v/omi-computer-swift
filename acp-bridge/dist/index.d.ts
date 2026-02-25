/**
 * ACP Bridge — translates between OMI's JSON-lines protocol and the
 * Agent Client Protocol (ACP) used by claude-code-acp.
 *
 * THIS IS THE DESKTOP APP FLOW. It is unrelated to the VM/agent-cloud flow
 * (agent-cloud/agent.mjs), which runs Claude Code SDK on a remote VM for
 * the Omi Agent feature. This bridge runs locally on the user's Mac.
 *
 * Session lifecycle:
 * 1. warmup  → session/new (system prompt applied here, once)
 * 2. query   → session reused; systemPrompt field in the message is ignored
 *              unless the session was invalidated (cwd change → new session/new)
 * 3. The ACP SDK owns conversation history after session/new — do not inject
 *    it into the system prompt.
 *
 * Token counts:
 * session/prompt drives one or more internal Anthropic API calls (initial
 * response + one per tool-use round). The usage returned in the result is
 * the AGGREGATE across all those rounds. There are no separate sub-agents.
 *
 * Implementation flow:
 * 1. Create Unix socket server for omi-tools relay
 * 2. Spawn claude-code-acp as subprocess (JSON-RPC over stdio)
 * 3. Initialize ACP connection
 * 4. Handle auth if required (forward to Swift, wait for user action)
 * 5. On query: reuse or create session, send prompt, translate notifications → JSON-lines
 * 6. On interrupt: cancel the session
 */
export {};
