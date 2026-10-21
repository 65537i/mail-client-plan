import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

assert.equal(process.platform, "linux", "file-access tracing requires Linux");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "mail-client-file-audit-"));
const canaryPath = path.join(tempDirectory, "synthetic-canary.png");
const tracePrefix = path.join(tempDirectory, "file-access.trace");
const wrapperPath = path.join(tempDirectory, "mail-client-strace-wrapper.mjs");
const realBinary = path.join(root, "target", "release", "mail-client");

try {
  await writeFile(canaryPath, "Synthetic file-access canary; no user data.\n");
  await writeFile(
    wrapperPath,
    `#!/usr/bin/env node
import { spawn } from "node:child_process";

const tracedApp = spawn("strace", [
  "-ff",
  "-qq",
  "-e",
  "trace=%file",
  "-o",
  process.env.MAIL_CLIENT_FILE_TRACE_PREFIX,
  "--",
  process.env.MAIL_CLIENT_REAL_BINARY,
  ...process.argv.slice(2),
], { stdio: "inherit" });

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => tracedApp.kill(signal));
}

tracedApp.once("error", (error) => {
  console.error("Failed to start strace for the WebView process:", error);
  process.exitCode = 1;
});
tracedApp.once("close", (code) => {
  process.exitCode = code ?? 0;
});
`,
  );
  await chmod(wrapperPath, 0o755);

  const result = await new Promise((resolve, reject) => {
    const wdio = spawn("pnpm", ["exec", "wdio", "run", "wdio.security.conf.mjs"], {
      cwd: root,
      env: {
        ...process.env,
        MAIL_CLIENT_FILE_CANARY_URL: pathToFileURL(canaryPath).href,
        MAIL_CLIENT_FILE_TRACE_PREFIX: tracePrefix,
        MAIL_CLIENT_REAL_BINARY: realBinary,
        MAIL_CLIENT_WDIO_BINARY: wrapperPath,
      },
      stdio: "inherit",
    });
    wdio.once("error", reject);
    wdio.once("close", (code, signal) => resolve({ code, signal }));
  });

  if (result.code !== 0) {
    throw new Error(`WebView security tests failed (${result.signal ?? result.code})`);
  }

  const traceFiles = (await readdir(tempDirectory)).filter((name) =>
    name.startsWith("file-access.trace"),
  );
  assert(traceFiles.length > 0, "strace produced no file-access traces");

  let tracedApplication = false;
  for (const traceFile of traceFiles) {
    const trace = await readFile(path.join(tempDirectory, traceFile), "utf8");
    tracedApplication ||= trace.includes(realBinary);
    const canaryAccess = trace
      .split("\n")
      .find((line) => line.includes(canaryPath));
    assert.equal(
      canaryAccess,
      undefined,
      canaryAccess
        ? `the WebView process attempted to access the synthetic file canary: ${canaryAccess}`
        : `the WebView process attempted to access the synthetic file canary (${traceFile})`,
    );
  }
  assert(tracedApplication, "strace did not observe the Tauri application process");

  console.log(
    `AC-05 Linux file-access audit passed: synthetic canary not opened in ${traceFiles.length} traced process(es).`,
  );
} finally {
  await rm(tempDirectory, { recursive: true, force: true });
}
