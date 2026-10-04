import test from "node:test";
import assert from "node:assert/strict";
import { commandFacade } from "../src/core/tools/command-facade.mjs";

const commands = [
  { name: "fs_read", description: "Read", inputSchema: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } },
  { name: "fs_list", description: "List", inputSchema: { type: "object", properties: { path: { type: "string" } } } },
];

const facade = commandFacade({
  name: "fs",
  description: "Filesystem",
  commands,
  commandName: (name) => name.slice(3),
});

test("facade exposes compact top-level schema", () => {
  assert.equal(facade.tool.name, "fs");
  assert.deepEqual(facade.tool.inputSchema.required, ["command"]);
  assert.deepEqual(Object.keys(facade.tool.inputSchema.properties), ["command", "args"]);
});

test("help returns exact stored subcommand schema", async () => {
  const result = await facade.execute({ command: "help", args: { command: "read" } }, () => assert.fail("should not dispatch"));
  assert.deepEqual(result.schema.required, ["path"]);
  assert.equal(result.description, "Read");
});

test("dispatch maps subcommand to original handler name and nested args", async () => {
  const result = await facade.execute({ command: "read", args: { path: "/tmp/a" } }, (name, args) => ({ name, args }));
  assert.deepEqual(result, { name: "fs_read", args: { path: "/tmp/a" } });
  await assert.rejects(() => facade.execute({ command: "missing", args: {} }, () => null), /Unknown fs command/);
});
