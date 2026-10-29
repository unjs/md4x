import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { build as buildJsArtifacts } from "./js-artifacts.ts";

const selfPath = dirname(fileURLToPath(import.meta.url));
const projectDir = resolve(selfPath, "..");
const testDir = join(projectDir, "test");
const program = resolve("zig-out", "bin", "md4x");

let errCount = 0;

// The JS suites load gitignored build outputs (packages/md4x/build/*,
// lib/standalone.mjs). This runner owns the whole pipeline, so it rebuilds them
// rather than asserting about them — the vitest globalSetup is what refuses to
// run against stale ones when vitest is invoked on its own.
console.log("Building JS artifacts (wasm, host NAPI, standalone):");
try {
  buildJsArtifacts();
} catch {
  errCount++;
}
console.log();

// Parser-internal invariants (abort matrix, OOM sweep, golden SAX event trace).
// The .txt suites below can only diff rendered HTML, so these are the only
// guard on the emission path itself. The test artifact is pinned to a safe
// optimize mode in build.zig, independently of -Doptimize.
console.log("Testing parser internals (zig build test):");
try {
  execFileSync("zig", ["build", "test"], {
    cwd: projectDir,
    stdio: "inherit",
  });
} catch {
  errCount++;
}
console.log();

// How test/prog.py turns `-p PROGRAM` into an argv — every Python suite below
// goes through it, so a broken split fails all of them at once.
console.log("Testing program invocation:");
try {
  execFileSync("python3", ["prog-tests.py", program], {
    cwd: testDir,
    stdio: "inherit",
  });
} catch {
  errCount++;
}
console.log();

const testSuites = readdirSync(testDir)
  .filter((f) => f.endsWith(".txt"))
  .sort();

for (const suite of testSuites) {
  console.log(`Testing ${suite}`);
  try {
    execFileSync("python3", ["run-testsuite.py", "-s", suite, "-p", program], {
      cwd: testDir,
      stdio: "inherit",
    });
  } catch {
    errCount++;
  }
  console.log();
}

console.log("Testing pathological inputs:");
try {
  execFileSync("python3", ["pathological-tests.py", "-p", program], {
    cwd: testDir,
    stdio: "inherit",
  });
} catch {
  errCount++;
}
console.log();

// The JS bindings (napi, wasm, standalone). The .txt suites above only ever
// reach the CLI, so without this the JS layer is untested by the "everything"
// command.
console.log("Testing JS bindings (vitest):");
try {
  execFileSync("bun", ["vitest", "run"], {
    cwd: projectDir,
    stdio: "inherit",
  });
} catch {
  errCount++;
}

process.exit(errCount);
