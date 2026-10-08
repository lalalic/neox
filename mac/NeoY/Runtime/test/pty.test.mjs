import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";

import { configurePty } from "../src/core/tools/pty.mjs";

test("PTY requires an initialized job directory", () => {
  assert.throws(
    () => configurePty({}),
    /PTY job directory is not configured/,
  );

  assert.doesNotThrow(() => configurePty({ JOB_DIR: os.tmpdir() }));
});
