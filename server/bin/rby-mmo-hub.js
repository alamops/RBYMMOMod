#!/usr/bin/env node
'use strict';

/*
 * The executable. Everything it does is one call into lib/cli.js.
 *
 * The split is on purpose: a shim this thin has no behaviour of its own to
 * test, so the whole CLI can be driven in-process -- `run(argv, io)` with
 * captured streams -- instead of by spawning a shell and parsing what came
 * back. Anything that lived here would be the one part of the tool no test
 * could reach.
 *
 * process.exitCode rather than process.exit(): exit() tears the process down
 * immediately and can truncate output still buffered for a pipe, which is
 * exactly how `rby-mmo-hub invite > code.txt` would end up with an empty file
 * holding the only copy of a join code. Setting the code lets Node finish
 * flushing and leave on its own.
 */

const { run } = require('../lib/cli.js');

run(process.argv.slice(2), {
  stdout: process.stdout,
  stderr: process.stderr,
  stdin: process.stdin,
  env: process.env,
  cwd: process.cwd(),
}).then((code) => {
  process.exitCode = Number.isInteger(code) ? code : 0;
}).catch((err) => {
  // run() is written not to reject; if it ever does, that is a bug in this
  // software and the host still deserves a sentence rather than a stack.
  try {
    process.stderr.write(`rby-mmo-hub: ${err && err.message ? err.message : String(err)}\n`);
  } catch (writeErr) {
    /* the terminal is gone; the exit code is the only signal left */
  }
  process.exitCode = 1;
});
