import test from "node:test";
import assert from "node:assert/strict";
import { commandFacade } from "../src/core/tools/command-facade.mjs";

const commands = [
  { name: "fs_read", description: "Read", inputSchema: { type: "object", properties: { path: { type: "string" }, encoding: { type: "string", enum: ["utf8", "base64"] } }, required: ["path"], additionalProperties: false } },
  { name: "fs_list", description: "List", inputSchema: { type: "object", properties: { path: { type: "string" } } } },
];

const facade = commandFacade({
  name: "fs",
  description: "Filesystem",
  commands,
  commandName: (name) => name.slice(3),
  examples: [{ command: "read", args: { path: "~/README.md" } }],
});

test("facade exposes compact top-level schema", () => {
  assert.equal(facade.tool.name, "fs");
  assert.deepEqual(facade.tool.inputSchema.required, ["command"]);
  assert.deepEqual(Object.keys(facade.tool.inputSchema.properties), ["command", "args"]);
  assert.deepEqual(facade.tool.inputSchema.properties.command.enum, ["help", "list", "read"]);
  assert.deepEqual(facade.tool.inputSchema.examples, [{ command: "read", args: { path: "~/README.md" } }]);
});

test("help returns exact stored subcommand schema", async () => {
  const result = await facade.execute({ command: "help", args: { command: "read" } }, () => assert.fail("should not dispatch"));
  assert.deepEqual(result.schema.required, ["path"]);
  assert.equal(result.description, "Read");
});

test("dispatch maps subcommand to original handler name and nested args", async () => {
  const result = await facade.execute({ command: "read", args: { path: "/tmp/a" } }, (name, args) => ({ name, args }));
  assert.deepEqual(result, { name: "fs_read", args: { path: "/tmp/a" } });
  await assert.rejects(() => facade.execute({ command: "missing", args: {} }, () => null), /Unknown fs command.*help/);
});

test("help lists schemas and validates nested arguments before dispatch", async () => {
  const help = await facade.execute({ command: "help", args: {} }, () => assert.fail("should not dispatch"));
  assert.deepEqual(help.examples, [{ command: "read", args: { path: "~/README.md" } }]);
  assert.deepEqual(help.commands.find((entry) => entry.command === "read").schema.required, ["path"]);

  await assert.rejects(
    () => facade.execute({ command: "read", args: { path: "/tmp/a", encoding: "utf16" } }, () => assert.fail("invalid enum dispatched")),
    /args for fs\.read\.encoding must be one of: utf8, base64/,
  );
  await assert.rejects(
    () => facade.execute({ command: "read", args: { path: "/tmp/a", extra: true } }, () => assert.fail("unknown arg dispatched")),
    /args for fs\.read\.extra is not supported.*help/,
  );
});
