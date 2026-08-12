import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const selfPath = dirname(fileURLToPath(import.meta.url));
const projectDir = resolve(selfPath, "..");
const testDir = join(projectDir, "test");
const program = resolve("zig-out", "bin", "md4x");

let errCount = 0;

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

process.exit(errCount);
