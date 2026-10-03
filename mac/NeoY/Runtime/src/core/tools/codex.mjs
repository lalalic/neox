export const CODEX_TOOLS = [
{
    name: "codex_thread_read",
    title: "Read Codex thread",
    description: "Read a stored local Codex thread through codex app-server without resuming it or starting a model turn. Set include_turns to true for the full persisted history.",
    inputSchema: {
      type: "object",
      properties: {
        thread_id: { type: "string" },
        include_turns: { type: "boolean", default: true },
        timeout_ms: { type: "integer", minimum: 1000, maximum: 120000, default: 30000 },
      },
      required: ["thread_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "codex_thread_list",
    title: "List Codex threads",
    description: "Page through stored local Codex threads without resuming them or starting model turns. Supports search, cwd, archived state, sorting, and cursor pagination.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
        cursor: { type: "string" },
        search_term: { type: "string" },
        cwd: { type: "string" },
        archived: { type: "boolean" },
        is_pinned: { type: "boolean" },
        use_state_db_only: { type: "boolean", default: false },
        model_providers: { type: "array", items: { type: "string" } },
        source_kinds: {
          type: "array",
          items: { type: "string", enum: ["cli", "vscode", "exec", "appServer", "subAgent", "subAgentReview", "subAgentCompact", "subAgentThreadSpawn", "subAgentOther", "unknown"] },
        },
        sort_key: { type: "string", enum: ["created_at", "updated_at", "recency_at"], default: "recency_at" },
        sort_direction: { type: "string", enum: ["asc", "desc"], default: "desc" },
        timeout_ms: { type: "integer", minimum: 1000, maximum: 120000, default: 30000 },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
{
    name: "codex_thread_turns_list",
    title: "Page Codex thread turns",
    description: "Page a stored Codex thread's turns without resuming it or starting a model turn. Use items_view=full to recover complete persisted turn items when codex_thread_read is too large for one response.",
    inputSchema: {
      type: "object",
      properties: {
        thread_id: { type: "string" },
        limit: { type: "integer", minimum: 1, maximum: 200, default: 50 },
        cursor: { type: "string" },
        sort_direction: { type: "string", enum: ["asc", "desc"], default: "asc" },
        items_view: { type: "string", enum: ["notLoaded", "summary", "full"], default: "full" },
        timeout_ms: { type: "integer", minimum: 1000, maximum: 120000, default: 30000 },
      },
      required: ["thread_id"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }
];

export async function handleCodex(name, args, context) {
  const { optionalString, optionalBoolean, optionalInteger, requireString, optionalStringArray, resolvePath, callCodexAppServer, audit } = context;
  switch (name) {
        case "codex_thread_read": {
          const threadId = requireString(args, "thread_id");
          const includeTurns = optionalBoolean(args, "include_turns", true);
          const timeoutMs = optionalInteger(args, "timeout_ms", 30_000, 1_000, 120_000);
          const result = await callCodexAppServer("thread/read", { threadId, includeTurns }, timeoutMs);
          await audit(name, args, { threadId, includeTurns, ok: true });
          return result;
        }
    
        case "codex_thread_list": {
          const timeoutMs = optionalInteger(args, "timeout_ms", 30_000, 1_000, 120_000);
          const params = {
            limit: optionalInteger(args, "limit", 50, 1, 200),
            sortKey: optionalString(args, "sort_key", "recency_at"),
            sortDirection: optionalString(args, "sort_direction", "desc"),
          };
          if (args?.cursor !== undefined) params.cursor = optionalString(args, "cursor");
          if (args?.search_term !== undefined) params.searchTerm = optionalString(args, "search_term");
          if (args?.cwd !== undefined) params.cwd = resolvePath(optionalString(args, "cwd"));
          if (args?.archived !== undefined) params.archived = optionalBoolean(args, "archived");
          if (args?.is_pinned !== undefined) params.isPinned = optionalBoolean(args, "is_pinned");
          if (args?.use_state_db_only !== undefined) params.useStateDbOnly = optionalBoolean(args, "use_state_db_only");
          if (args?.model_providers !== undefined) params.modelProviders = optionalStringArray(args, "model_providers");
          if (args?.source_kinds !== undefined) params.sourceKinds = optionalStringArray(args, "source_kinds");
          const result = await callCodexAppServer("thread/list", params, timeoutMs);
          await audit(name, args, { count: Array.isArray(result?.data) ? result.data.length : null, ok: true });
          return result;
        }
    
        case "codex_thread_turns_list": {
          const timeoutMs = optionalInteger(args, "timeout_ms", 30_000, 1_000, 120_000);
          const params = {
            threadId: requireString(args, "thread_id"),
            limit: optionalInteger(args, "limit", 50, 1, 200),
            sortDirection: optionalString(args, "sort_direction", "asc"),
            itemsView: optionalString(args, "items_view", "full"),
          };
          if (args?.cursor !== undefined) params.cursor = optionalString(args, "cursor");
          const result = await callCodexAppServer("thread/turns/list", params, timeoutMs);
          await audit(name, args, { threadId: params.threadId, count: Array.isArray(result?.data) ? result.data.length : null, ok: true });
          return result;
        }
    default: throw new Error("Unknown codex tool: " + name);
  }
}
