import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdtemp, open, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { verifyMacosFileTrace } from "./macos-file-trace.mjs";

assert.equal(process.platform, "darwin", "file-access tracing requires macOS");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tempDirectory = await mkdtemp(path.join(os.tmpdir(), "mail-client-file-audit-"));
const canaryName = `mc-${randomUUID().slice(0, 12)}.png`;
const canaryPath = path.join(tempDirectory, canaryName);
const tracePath = path.join(tempDirectory, "fs-usage.trace");
const tracePidPath = path.join(tempDirectory, "fs-usage.pid");

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
    [
      "-n", "/bin/sh", "-c",
      'echo "$$" > "$1"; exec /usr/bin/fs_usage -w -f filesys -t 90',
      "mail-client-file-audit", tracePidPath,
    ],
    { stdio: ["ignore", traceFile.fd, traceFile.fd] },
  );
  const traceClose = waitForClose(trace).then(
    (result) => ({ result }),
    (error) => ({ error }),
  );

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
    assert(
      trace.exitCode === null && trace.signalCode === null,
      "fs_usage stopped before the WebView tests finished; audit coverage is incomplete",
    );
  } finally {
    try {
      if (trace.exitCode === null && trace.signalCode === null) {
        const pid = (await readFile(tracePidPath, "utf8")).trim();
        assert(/^[1-9]\d*$/.test(pid), "fs_usage returned an invalid process ID");
        const stop = spawn("sudo", ["-n", "/bin/kill", "-INT", pid], {
          stdio: "inherit",
        });
        const stopResult = await waitForClose(stop);
        assert.equal(stopResult.code, 0, "failed to stop the privileged fs_usage process");
      }
    } finally {
      try {
        const closed = await traceClose;
        if (closed.error) throw closed.error;
        traceResult = closed.result;
      } finally {
        await traceFile.close();
      }
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
  verifyMacosFileTrace(traceOutput, canaryName);
} finally {
  await rm(tempDirectory, { recursive: true, force: true });
}

console.log("AC-05 macOS file-access audit passed: canary absent from the fs_usage trace.");
