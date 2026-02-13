import { query } from "@anthropic-ai/claude-agent-sdk";
import type { SDKUserMessage, Query } from "@anthropic-ai/claude-agent-sdk";
import { createOmiMcpServer, resolveToolCall } from "./omi-tools.js";
import type {
  InboundMessage,
  OutboundMessage,
  QueryMessage,
} from "./protocol.js";
import { createInterface } from "readline";
import { fileURLToPath } from "url";
import { dirname, join } from "path";
import { randomUUID } from "crypto";

// Resolve path to bundled @playwright/mcp CLI
const __dirname = dirname(fileURLToPath(import.meta.url));
const playwrightCli = join(__dirname, "..", "node_modules", "@playwright", "mcp", "cli.js");

// --- Helpers ---

function send(msg: OutboundMessage): void {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function logErr(msg: string): void {
  process.stderr.write(`[agent-bridge] ${msg}\n`);
}

// --- MCP Server (OMI tools) ---

const omiServer = createOmiMcpServer();

// --- MessageChannel: async queue for follow-up messages ---

class MessageChannel<T> {
  private queue: T[] = [];
  private waiter: { resolve: (v: T) => void; reject: (e: Error) => void } | null = null;
  private closed = false;

  push(value: T) {
    if (this.closed) return;
    if (this.waiter) {
      const w = this.waiter;
      this.waiter = null;
      w.resolve(value);
    } else {
      this.queue.push(value);
    }
  }

  async pull(): Promise<T> {
    if (this.queue.length > 0) {
      return this.queue.shift()!;
    }
    if (this.closed) {
      throw new Error("channel closed");
    }
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
    });
  }

  close() {
    this.closed = true;
    if (this.waiter) {
      this.waiter.reject(new Error("channel closed"));
      this.waiter = null;
    }
  }
}

// --- Active query state ---

let activeAbort: AbortController | null = null;
let activeQuery: Query | null = null;
let followUpChannel: MessageChannel<string> | null = null;
let queryDone = false;

// --- Handle a query from Swift ---

async function handleQuery(msg: QueryMessage): Promise<void> {
  // Cancel any prior query
  if (activeAbort) {
    activeAbort.abort();
    activeAbort = null;
  }
  activeQuery = null;
  followUpChannel?.close();
  followUpChannel = null;

  const abortController = new AbortController();
  activeAbort = abortController;
  queryDone = false;

  const channel = new MessageChannel<string>();
  followUpChannel = channel;

  // Session ID for constructing SDKUserMessage objects
  const inputSessionId = randomUUID();

  // Async generator that yields the initial prompt, then follow-ups from the channel
  async function* userMessageStream(): AsyncGenerator<SDKUserMessage> {
    yield {
      type: "user",
      message: { role: "user", content: msg.prompt },
      parent_tool_use_id: null,
      session_id: inputSessionId,
    };

    while (true) {
      try {
        const text = await channel.pull();
        yield {
          type: "user",
          message: { role: "user", content: text },
          parent_tool_use_id: null,
          session_id: inputSessionId,
        };
      } catch {
        // Channel closed — no more input
        return;
      }
    }
  }

  try {
    // Each query is standalone — conversation history comes via systemPrompt
    // This ensures cross-platform sync (mobile messages are included in context)
    const options: Record<string, unknown> = {
      model: "claude-opus-4-6",
      abortController,
      systemPrompt: msg.systemPrompt,
      allowedTools: [
        "Read",
        "Write",
        "Edit",
        "Bash",
        "Glob",
        "Grep",
        "WebSearch",
        "WebFetch",
      ],
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      maxTurns: 15,
      cwd: msg.cwd || process.env.HOME || "/",
      mcpServers: {
        "omi-tools": omiServer,
        "playwright": {
          command: process.execPath,
          args: [playwrightCli],
        },
      },
      includePartialMessages: true,
    };

    let sessionId = "";
    let fullText = "";
    let costUsd = 0;

    // Track pending tool calls so we can mark them completed when new text arrives
    const pendingTools: string[] = [];

    const q = query({ prompt: userMessageStream(), options: options as any });
    activeQuery = q;

    for await (const message of q) {
      if (abortController.signal.aborted) break;

      switch (message.type) {
        case "system":
          if ("session_id" in message) {
            sessionId = message.session_id as string;
            send({ type: "init", sessionId });
          }
          break;

        case "stream_event": {
          const event = (message as any).event;

          // Detect tool_use start from streaming (before assistant message)
          if (
            event?.type === "content_block_start" &&
            event.content_block?.type === "tool_use"
          ) {
            const name = event.content_block.name as string;
            pendingTools.push(name);
            send({ type: "tool_activity", name, status: "started" });
          }

          // Text deltas — if tools were pending, they're now complete
          if (
            event?.type === "content_block_delta" &&
            event.delta?.type === "text_delta"
          ) {
            if (pendingTools.length > 0) {
              for (const name of pendingTools) {
                send({ type: "tool_activity", name, status: "completed" });
              }
              pendingTools.length = 0;
            }
            const text = event.delta.text as string;
            fullText += text;
            send({ type: "text_delta", text });
          }
          break;
        }

        case "assistant": {
          // Complete assistant message — extract text from content blocks
          const content = (message as any).message?.content;
          if (Array.isArray(content)) {
            for (const block of content) {
              if (block.type === "text" && typeof block.text === "string") {
                // Only use if we didn't get streaming deltas
                if (!fullText) {
                  fullText = block.text;
                  send({ type: "text_delta", text: block.text });
                }
              }
            }
          }
          break;
        }

        case "result": {
          // Mark any remaining pending tools as completed
          for (const name of pendingTools) {
            send({ type: "tool_activity", name, status: "completed" });
          }
          pendingTools.length = 0;

          const result = message as any;
          if (result.subtype === "success" || result.subtype === "interrupt") {
            // Accumulate cost across turns (follow-ups produce multiple results)
            costUsd += (result.total_cost_usd || 0);
            // Use result.result as final text if we didn't capture anything
            if (!fullText && result.result) {
              fullText = result.result;
            }
          } else {
            // Error result
            const errors = result.errors || [];
            send({
              type: "error",
              message: `Agent error (${result.subtype}): ${errors.join(", ")}`,
            });
          }
          break;
        }
      }
    }

    send({ type: "result", text: fullText, sessionId, costUsd });
  } catch (err: unknown) {
    // Silently handle abort — it's expected when a new query supersedes the old one
    if (abortController.signal.aborted) {
      logErr("Query aborted (superseded by new query)");
      return;
    }
    const errMsg = err instanceof Error ? err.message : String(err);
    logErr(`Query error: ${errMsg}`);
    send({ type: "error", message: errMsg });
  } finally {
    if (activeAbort === abortController) {
      activeAbort = null;
    }
    activeQuery = null;
    followUpChannel = null;
    queryDone = true;
  }
}

// --- Follow-up and interrupt handlers ---

async function handleFollowUp(text: string): Promise<void> {
  if (!activeQuery || queryDone || !followUpChannel) {
    logErr("Follow-up ignored: no active query");
    return;
  }
  try {
    await activeQuery.interrupt();
    followUpChannel.push(text);
    logErr(`Follow-up delivered: "${text.slice(0, 50)}..."`);
  } catch (err) {
    logErr(`Follow-up error: ${err}`);
  }
}

async function handleInterrupt(): Promise<void> {
  if (!activeQuery || queryDone) {
    logErr("Interrupt ignored: no active query");
    return;
  }
  try {
    await activeQuery.interrupt();
  } catch (err) {
    logErr(`Interrupt error: ${err}`);
  }
  followUpChannel?.close();
  queryDone = true;
  logErr("Query interrupted by user");
}

// Prevent unhandled rejections from crashing the bridge process
process.on("unhandledRejection", (reason) => {
  logErr(`Unhandled rejection: ${reason}`);
});

// --- Main: read JSON lines from stdin ---

const rl = createInterface({ input: process.stdin, terminal: false });

rl.on("line", (line: string) => {
  if (!line.trim()) return;

  let msg: InboundMessage;
  try {
    msg = JSON.parse(line) as InboundMessage;
  } catch {
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

    case "follow_up":
      handleFollowUp(msg.text).catch((err) => {
        logErr(`Unhandled follow-up error: ${err}`);
      });
      break;

    case "interrupt":
      handleInterrupt().catch((err) => {
        logErr(`Unhandled interrupt error: ${err}`);
      });
      break;

    case "stop":
      logErr("Received stop signal, exiting");
      if (activeAbort) activeAbort.abort();
      process.exit(0);
      break;

    default:
      logErr(`Unknown message type: ${(msg as any).type}`);
  }
});

rl.on("close", () => {
  logErr("stdin closed, exiting");
  if (activeAbort) activeAbort.abort();
  process.exit(0);
});

// Signal readiness
send({ type: "init", sessionId: "" });
logErr("Bridge started, waiting for queries...");
