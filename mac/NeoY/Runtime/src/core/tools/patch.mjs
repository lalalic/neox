export const PATCH_TOOLS = [
{
    name: "apply_file_patch",
    title: "Apply file patch",
    description: "Apply a standard unified diff (git apply format). REQUIRED: patch (full diff string) and cwd (absolute working directory). Example patch: diff --git a/file.txt b/file.txt\\n--- a/file.txt\\n+++ b/file.txt\\n@@ -1 +1 @@\\n-old\\n+new\\n. Use check_only:true to validate before applying. Do not pass command/args wrappers or Codex Begin Patch markers. Supports reverse and three_way.",
    inputSchema: {
      type: "object",
      properties: {
        patch: { type: "string", minLength: 1 },
        cwd: { type: "string", minLength: 1 },
        check_only: { type: "boolean", default: false },
        reverse: { type: "boolean", default: false },
        three_way: { type: "boolean", default: false },
      },
      required: ["patch", "cwd"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, idempotentHint: false, openWorldHint: false },
  }
];

export async function handlePatch(name, args, context) {
  const { HOME, DEFAULT_OUTPUT_BYTES, optionalString, optionalBoolean, requireString, runCommand, audit } = context;
  switch (name) {
        case "apply_file_patch": {
          const patchText = requireString(args, "patch");
          const cwd = requireString(args, "cwd");
          const validDiff = /^(?:diff --git |--- )/m.test(patchText) && /^\+\+\+ /m.test(patchText) && /^@@(?: |-|\d)/m.test(patchText);
          if (!validDiff || /\*\*\* Begin Patch|\*\*\* Update File|\*\*\* End Patch/.test(patchText)) {
            const error = { code: "INVALID_PATCH_FORMAT", message: "apply_file_patch requires a standard unified diff, not Codex Begin Patch format" };
            await audit(name, args, { exitCode: 2, reason: error.code });
            return { exitCode: 2, stdout: "", stderr: error.message, error };
          }
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
