export const AUDIT_TOOLS = [
{
    name: "audit_tail",
    title: "Read bridge audit log",
    description: "Return the tail of the bridge's local JSONL audit log. The default metadata mode redacts common token patterns and stores only an argument preview plus a hash.",
    inputSchema: {
      type: "object",
      properties: {
        max_bytes: { type: "integer", minimum: 1024, maximum: 8000000, default: 200000 },
        tool: { type: "string", description: "Only return entries for this tool name." },
        category: { type: "string", description: "Only return entries for this normalized category, such as missing_parameter or platform_rejection." },
        event: { type: "string", description: "Only return entries for this event, such as tool_input_error or platform_rejection." },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }
];

export async function handleAudit(name, args, context) {
  const { AUDIT_LOG, optionalInteger, optionalString, tailFile, audit } = context;
  switch (name) {
        case "audit_tail": {
          const maxBytes = optionalInteger(args, "max_bytes", 200_000, 1_024, 8_000_000);
          const tool = optionalString(args, "tool", null);
          const category = optionalString(args, "category", null);
          const event = optionalString(args, "event", null);
          const raw = await tailFile(AUDIT_LOG, maxBytes);
          if (!tool && !category && !event) {
            const result = { path: AUDIT_LOG, ...raw };
            await audit(name, args, { returnedBytes: result.returnedBytes });
            return result;
          }
          const entries = raw.text.split("\n").filter(Boolean).flatMap((line) => {
            try { return [JSON.parse(line)]; } catch { return []; }
          }).filter((entry) =>
            (!tool || entry.tool === tool) &&
            (!category || entry.category === category) &&
            (!event || entry.event === event)
          );
          const text = entries.map((entry) => JSON.stringify(entry)).join("\n") + (entries.length ? "\n" : "");
          const result = { path: AUDIT_LOG, ...raw, text, matched: entries.length, returnedBytes: Buffer.byteLength(text) };
          await audit(name, args, { returnedBytes: result.returnedBytes, matched: entries.length });
          return result;
        }
    default: throw new Error("Unknown audit tool: " + name);
  }
}
