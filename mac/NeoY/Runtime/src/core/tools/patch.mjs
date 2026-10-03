export const PATCH_TOOLS = [
{
    name: "apply_patch",
    title: "Apply unified diff",
    description: "Apply a unified diff using git apply in the specified working directory. This does not invoke a model and can modify any paths permitted by git apply and the host OS.",
    inputSchema: {
      type: "object",
      properties: {
        patch: { type: "string", minLength: 1 },
        cwd: { type: "string" },
        check_only: { type: "boolean", default: false },
        reverse: { type: "boolean", default: false },
        three_way: { type: "boolean", default: false },
      },
      required: ["patch"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  }
];

export async function handlePatch(name, args, context) {
  const { HOME, DEFAULT_OUTPUT_BYTES, optionalString, optionalBoolean, requireString, runCommand, audit } = context;
  switch (name) {
        case "apply_patch": {
          const patchText = requireString(args, "patch");
          const cwd = optionalString(args, "cwd", HOME);
          const checkOnly = optionalBoolean(args, "check_only", false);
          const reverse = optionalBoolean(args, "reverse", false);
          const threeWay = optionalBoolean(args, "three_way", false);
          const flags = ["apply", "--recount", "--whitespace=nowarn"];
          if (checkOnly) flags.push("--check");
          if (reverse) flags.push("--reverse");
          if (threeWay) flags.push("--3way");
          const result = await runCommand({
            command: `git ${flags.map((flag) => JSON.stringify(flag)).join(" ")} -`,
            cwd,
            stdin: patchText,
            timeoutMs: 120_000,
            maxOutputBytes: DEFAULT_OUTPUT_BYTES,
          });
          await audit(name, args, { exitCode: result.exitCode, checkOnly, reverse, threeWay, durationMs: result.durationMs });
          return result;
        }
    default: throw new Error("Unknown patch tool: " + name);
  }
}
