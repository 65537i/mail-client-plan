import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  decodeWindowsFileTrace,
  verifyWindowsFileTrace,
} from "./windows-file-trace.mjs";

assert.equal(process.platform, "win32", "file-access tracing requires Windows");
assert(process.env.MAIL_CLIENT_PROCMON_PATH, "MAIL_CLIENT_PROCMON_PATH is required");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const procmonPath = path.resolve(process.env.MAIL_CLIENT_PROCMON_PATH);
const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "mail-client-file-audit-"));
const canaryPath = path.join(temporaryDirectory, `mc-${randomUUID().slice(0, 12)}.png`);
const backingFile = path.join(temporaryDirectory, "process-monitor.pml");
const csvFile = path.join(temporaryDirectory, "process-monitor.csv");

function waitWithTimeout(promise, milliseconds) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve({ timedOut: true }), milliseconds);
    promise.then((result) => {
      clearTimeout(timer);
      resolve(result);
    });
  });
}

function waitForProcess(child) {
  return new Promise((resolve) => {
    child.once("error", (error) => resolve({ error }));
    child.once("close", (code, signal) => resolve({ code, signal }));
  });
}

async function runProcmon(args, description) {
  const child = spawn(procmonPath, args, {
    stdio: "ignore",
    windowsHide: true,
  });
  const childExit = waitForProcess(child);
  const result = await waitWithTimeout(childExit, 20_000);
  if (result.timedOut) {
    child.kill();
    await childExit;
    throw new Error(`Process Monitor ${description} timed out`);
  }
  if (result.error) {
    throw new Error(`Process Monitor ${description} failed to start`);
  }
  assert.equal(result.code, 0, `Process Monitor ${description} exited unsuccessfully`);
}

let capture;
let captureExit;

try {
  await writeFile(canaryPath, "Synthetic file-access canary; no user data.\n");
  capture = spawn(
    procmonPath,
    ["/AcceptEula", "/Quiet", "/Minimized", "/NoFilter", "/BackingFile", backingFile],
    { stdio: "ignore", windowsHide: true },
  );
  captureExit = waitForProcess(capture);
  assert(capture.pid, "Process Monitor capture process did not start");
  await new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, 1500);
    captureExit.then((result) => {
      clearTimeout(timer);
      reject(
        new Error(
          result.error
            ? "Process Monitor capture failed to start"
            : `Process Monitor capture stopped before the WebView test (${result.signal ?? result.code})`,
        ),
      );
    });
  });
  assert.equal(capture.exitCode, null, "Process Monitor capture exited during startup");
  await access(backingFile);

  const positiveControl = spawn(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "[System.IO.File]::ReadAllBytes($env:MAIL_CLIENT_FILE_CANARY) | Out-Null",
    ],
    {
      env: {
        ...process.env,
        MAIL_CLIENT_FILE_CANARY: canaryPath,
      },
      stdio: "ignore",
      windowsHide: true,
    },
  );
  const positiveControlResult = await waitForProcess(positiveControl);
  if (positiveControlResult.error) {
    throw new Error("Failed to start the synthetic-canary positive control");
  }
  assert.equal(
    positiveControlResult.code,
    0,
    "PowerShell synthetic-canary positive control failed",
  );

  const command = spawn(
    process.env.ComSpec ?? "cmd.exe",
    ["/d", "/s", "/c", "pnpm exec wdio run wdio.security.conf.mjs"],
    {
      cwd: root,
      env: {
        ...process.env,
        MAIL_CLIENT_FILE_CANARY_URL: pathToFileURL(canaryPath).href,
      },
      stdio: "inherit",
      windowsHide: true,
    },
  );
  const webviewResult = await waitForProcess(command);
  if (webviewResult.error) {
    throw new Error("Failed to start the Windows WebView security tests");
  }
  assert.equal(
    webviewResult.code,
    0,
    `Windows WebView security tests failed (${webviewResult.signal ?? webviewResult.code})`,
  );
  assert.equal(capture.exitCode, null, "Process Monitor capture stopped during the WebView tests");

  await runProcmon(["/AcceptEula", "/Terminate"], "capture shutdown");
  const captureResult = await waitWithTimeout(captureExit, 10_000);
  assert(!captureResult.timedOut, "Process Monitor capture did not stop after termination");
  if (captureResult.error) throw new Error("Process Monitor capture failed while shutting down");

  const backingFileStats = await stat(backingFile);
  assert(backingFileStats.size > 0, "Process Monitor produced an empty capture");
  assert(
    backingFileStats.size <= 256 * 1024 * 1024,
    "Process Monitor capture exceeded the 256 MiB safety limit",
  );

  await runProcmon(
    ["/AcceptEula", "/Quiet", "/OpenLog", backingFile, "/SaveAs", csvFile],
    "CSV export",
  );
  const csvStats = await stat(csvFile);
  assert(
    csvStats.size <= 256 * 1024 * 1024,
    "Process Monitor CSV export exceeded the 256 MiB safety limit",
  );
  const trace = decodeWindowsFileTrace(await readFile(csvFile));
  const result = verifyWindowsFileTrace(trace, canaryPath);
  console.log(
    `AC-05 Windows audit: Procmon positive-control ReadFile events=${result.positiveControlEvents}; unexpected synthetic-canary events=${result.canaryEvents - result.positiveControlEvents}.`,
  );
  console.log(
    "AC-05 Windows file-access audit passed for the observed application and WebView2 processes; complete descendant coverage remains unverified.",
  );
} finally {
  try {
    if (capture?.pid && capture.exitCode === null && capture.signalCode === null) {
      await runProcmon(["/AcceptEula", "/Terminate"], "capture shutdown");
      const result = await waitWithTimeout(captureExit, 10_000);
      assert(!result.timedOut, "Process Monitor capture did not stop after termination");
      if (result.error) throw new Error("Process Monitor capture failed while shutting down");
    }
  } finally {
    await rm(temporaryDirectory, { recursive: true, force: true });
  }
}
