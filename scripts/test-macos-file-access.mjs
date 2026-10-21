import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

assert.equal(process.platform, "darwin", "file-access tracing requires macOS");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "mail-client-file-audit-"));
const canaryName = `mc-${randomUUID().slice(0, 12)}.png`;
const canaryPath = path.join(tempDirectory, canaryName);
const tracePath = path.join(tempDirectory, "fs-usage.trace");

const waitForClose = (child) =>
  new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal }));
  });

try {
  await writeFile(canaryPath, "Synthetic file-access canary; no user data.\n");

  const traceFile = await open(tracePath, "w");
  const trace = spawn(
    "sudo",
    ["-n", "fs_usage", "-w", "-f", "filesys", "-t", "90"],
    { stdio: ["ignore", traceFile.fd, traceFile.fd] },
  );
  const traceClose = waitForClose(trace);
  void traceClose.catch(() => {});

  let wdioResult;
  let traceResult;
  try {
    await new Promise((resolve) => setTimeout(resolve, 1500));
    assert.equal(
      trace.exitCode,
      null,
      "fs_usage exited before the WebView test; root tracing may be unavailable",
    );

    const wdio = spawn("pnpm", ["exec", "wdio", "run", "wdio.security.conf.mjs"], {
      cwd: root,
      env: {
        ...process.env,
        MAIL_CLIENT_FILE_CANARY_URL: pathToFileURL(canaryPath).href,
      },
      stdio: "inherit",
    });
    wdioResult = await waitForClose(wdio);
  } finally {
    if (trace.exitCode === null && trace.signalCode === null) {
      trace.kill("SIGINT");
    }
    try {
      traceResult = await traceClose;
    } finally {
      await traceFile.close();
    }
  }

  if (wdioResult.code !== 0) {
    throw new Error(`WebView security tests failed (${wdioResult.signal ?? wdioResult.code})`);
  }

  assert(
    traceResult.code === 0 || traceResult.code === 130 || traceResult.signal === "SIGINT",
    `fs_usage exited unexpectedly (${traceResult.signal ?? traceResult.code})`,
  );

  const traceOutput = await readFile(tracePath, "utf8");
  assert(
    traceOutput
      .split(/\r?\n/)
      .some((line) => /\bmail-client(?:\.\d+)?\s*$/.test(line)),
    "fs_usage did not observe filesystem activity from the Tauri application",
  );
  assert(
    !traceOutput.includes(canaryName),
    "the WebView process attempted to access the synthetic file canary",
  );
} finally {
  await rm(tempDirectory, { recursive: true, force: true });
}

console.log("AC-05 macOS file-access audit passed: canary absent from the fs_usage trace.");
