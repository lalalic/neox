export const AUDIT_TOOLS = [
{
    name: "audit_tail",
    title: "Read bridge audit log",
    description: "Return the tail of the bridge's local JSONL audit log. The default metadata mode redacts common token patterns and stores only an argument preview plus a hash.",
    inputSchema: {
      type: "object",
      properties: { max_bytes: { type: "integer", minimum: 1024, maximum: 8000000, default: 200000 } },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }
];

export async function handleAudit(name, args, context) {
  const { AUDIT_LOG, optionalInteger, tailFile, audit } = context;
  switch (name) {
        case "audit_tail": {
          const maxBytes = optionalInteger(args, "max_bytes", 200_000, 1_024, 8_000_000);
          const result = { path: AUDIT_LOG, ...(await tailFile(AUDIT_LOG, maxBytes)) };
          await audit(name, args, { returnedBytes: result.returnedBytes });
          return result;
        }
    default: throw new Error("Unknown audit tool: " + name);
  }
}
