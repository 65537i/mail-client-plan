import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { fork, spawn } from "node:child_process";
import { access, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  decodeWindowsFileTrace,
  inspectWindowsFileTrace,
} from "./windows-file-trace.mjs";
import { createWindowsAuditCanary } from "./windows-audit-canary.mjs";

assert.equal(process.platform, "win32", "file-access tracing requires Windows");
assert(process.env.MAIL_CLIENT_PROCMON_PATH, "MAIL_CLIENT_PROCMON_PATH is required");

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const procmonPath = path.resolve(process.env.MAIL_CLIENT_PROCMON_PATH);

async function captureScenario(scenario) {
  const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "mail-client-file-audit-"));
  const canaryPath = path.join(temporaryDirectory, `mc-${randomUUID().slice(0, 12)}.png`);
  const positiveControlPath = path.join(temporaryDirectory, `mc-control-${randomUUID().slice(0, 12)}.png`);
  const excludedPath = path.join(temporaryDirectory, `mc-excluded-${randomUUID().slice(0, 12)}.png`);
  const backingFile = path.join(temporaryDirectory, "process-monitor.pml");
  const csvFile = path.join(temporaryDirectory, "process-monitor.csv");
  const filterConfig = path.join(temporaryDirectory, "canary-only.pmc");

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
  let command;
  let commandExit;
  const preparedAt = performance.now();
  let captureStartedAt;

  try {
    console.log(`Windows audit ${scenario}: canary creation requested UTC=${new Date().toISOString()}; mode=write-through`);
    const canaryBytes = await createWindowsAuditCanary(canaryPath);
    const canaryCreatedAt = new Date().toISOString();
    const canaryStats = await stat(canaryPath);
    assert.equal(canaryStats.size, canaryBytes, "Synthetic canary has an unexpected size");
    console.log(`Windows audit ${scenario}: canary flushed and closed UTC=${canaryCreatedAt}; bytes=${canaryStats.size}`);
    await writeFile(positiveControlPath, "Synthetic Process Monitor positive control.\n");
    await writeFile(excludedPath, "Synthetic Process Monitor filter negative control.\n");
    const filterSetup = spawn(
      "powershell.exe",
      [
        "-STA",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        path.join(root, "scripts", "configure-windows-procmon-filter.ps1"),
        "-ProcmonPath",
        procmonPath,
        "-CanaryPath",
        canaryPath,
        "-ControlPath",
        positiveControlPath,
        "-ConfigPath",
        filterConfig,
      ],
      { stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
    );
    let filterSetupOutput = "";
    filterSetup.stdout.setEncoding("utf8");
    filterSetup.stdout.on("data", (chunk) => {
      if (filterSetupOutput.length < 1024) filterSetupOutput += chunk;
    });
    filterSetup.stderr.resume();
    const filterSetupExit = waitForProcess(filterSetup);
    const filterSetupResult = await waitWithTimeout(filterSetupExit, 60_000);
    if (filterSetupResult.timedOut) {
      filterSetup.kill();
      await filterSetupExit;
      await runProcmon(["/AcceptEula", "/Terminate"], "filter setup cleanup");
      throw new Error("Process Monitor exact-path filter configuration timed out");
    }
    if (filterSetupResult.error) throw new Error("Failed to start Process Monitor filter configuration");
    const filterStage = filterSetupOutput.match(
      /PROC_MON_FILTER_FAILED_STAGE=([a-z-]+)/,
    )?.[1];
    assert.equal(
      filterSetupResult.code,
      0,
      filterStage
        ? `Process Monitor exact-path filter configuration failed at ${filterStage}`
        : "Process Monitor exact-path filter configuration failed",
    );
    command = fork(
      path.join(root, "scripts", "windows-audit-wdio.mjs"),
      [path.join(root, scenario === "baseline"
        ? "wdio.file-audit-baseline.conf.mjs" : "wdio.security.conf.mjs")],
      {
        cwd: root,
        env: {
          ...process.env,
          MAIL_CLIENT_FILE_CANARY_URL: scenario === "attack" ? pathToFileURL(canaryPath).href : undefined,
        },
        stdio: ["ignore", "inherit", "inherit", "ipc"],
        windowsHide: true,
      },
    );
    commandExit = waitForProcess(command);
    const ready = new Promise((resolve) => {
      command.once("message", (message) => resolve({ ready: message === "ready" }));
      commandExit.then(() => resolve({ ready: false }));
    });
    const prepared = await waitWithTimeout(ready, 60_000);
    assert(!prepared.timedOut && prepared.ready, "Windows audit WDIO preparation failed or timed out");
    console.log(`Windows audit ${scenario}: preparation milliseconds=${Math.round(performance.now() - preparedAt)}`);

    captureStartedAt = performance.now();
    console.log(`Windows audit ${scenario}: capture requested UTC=${new Date().toISOString()}; local UTC offset minutes=${-new Date().getTimezoneOffset()}`);
    capture = spawn(
      procmonPath,
      [
        "/AcceptEula",
        "/Quiet",
        "/Minimized",
        "/LoadConfig",
        filterConfig,
        "/BackingFile",
        backingFile,
      ],
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
      process.execPath,
      [
        "-e",
        "require('node:fs').readFileSync(process.env.MAIL_CLIENT_FILE_CANARY)",
      ],
      {
        env: {
          ...process.env,
          MAIL_CLIENT_FILE_CANARY: positiveControlPath,
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
      "Node synthetic-canary positive control failed",
    );
    const excludedControl = spawn(
      process.execPath,
      [
        "-e",
        "require('node:fs').readFileSync(process.env.MAIL_CLIENT_FILE_CANARY)",
      ],
      {
        env: {
          ...process.env,
          MAIL_CLIENT_FILE_CANARY: excludedPath,
        },
        stdio: "ignore",
        windowsHide: true,
      },
    );
    const excludedControlResult = await waitForProcess(excludedControl);
    if (excludedControlResult.error) {
      throw new Error("Failed to start the synthetic filter negative control");
    }
    assert.equal(excludedControlResult.code, 0, "Synthetic filter negative control failed");

    command.send("start");
    console.log(`Windows audit ${scenario}: WDIO start sent UTC=${new Date().toISOString()}`);
    const webviewResult = await commandExit;
    if (webviewResult.error) {
      throw new Error("Failed to start the Windows WebView security tests");
    }
    assert.equal(
      webviewResult.code,
      0,
      `Windows WebView security tests failed (${webviewResult.signal ?? webviewResult.code})`,
    );
    assert.equal(capture.exitCode, null, "Process Monitor capture stopped during the WebView tests");
    console.log(`Windows audit ${scenario}: WDIO finished UTC=${new Date().toISOString()}`);

    await runProcmon(["/AcceptEula", "/Terminate"], "capture shutdown");
    const captureResult = await waitWithTimeout(captureExit, 10_000);
    assert(!captureResult.timedOut, "Process Monitor capture did not stop after termination");
    if (captureResult.error) throw new Error("Process Monitor capture failed while shutting down");

    const backingFileStats = await stat(backingFile);
    console.log(
      `Windows audit ${scenario}: capture milliseconds=${Math.round(performance.now() - captureStartedAt)}; PML bytes=${backingFileStats.size}`,
    );
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
    console.log(`Windows audit ${scenario}: CSV bytes=${csvStats.size}`);
    assert(
      csvStats.size <= 256 * 1024 * 1024,
      "Process Monitor CSV export exceeded the 256 MiB safety limit",
    );
    const trace = decodeWindowsFileTrace(await readFile(csvFile));
    const result = inspectWindowsFileTrace(trace, canaryPath, positiveControlPath, excludedPath);
    console.log(
      `Windows audit ${scenario}: positive-control ReadFile events=${result.positiveControlEvents}; canary events=${result.canaryEvents.length}; diagnostics=${JSON.stringify(result.canaryDiagnostics)}`,
    );
    return result;
  } finally {
    try {
      if (capture?.pid && capture.exitCode === null && capture.signalCode === null) {
        await runProcmon(["/AcceptEula", "/Terminate"], "capture shutdown");
        const result = await waitWithTimeout(captureExit, 10_000);
        assert(!result.timedOut, "Process Monitor capture did not stop after termination");
        if (result.error) throw new Error("Process Monitor capture failed while shutting down");
      }
    } finally {
      try {
        if (command?.pid && command.exitCode === null && command.signalCode === null) {
          command.kill();
          await commandExit;
        }
      } finally {
        await rm(temporaryDirectory, { recursive: true, force: true });
      }
    }
  }
}

const baseline = await captureScenario("baseline");
const attack = await captureScenario("attack");
assert.equal(attack.canaryEvents.length, 0, "Windows attack capture contains unexpected canary events");
assert.equal(baseline.canaryEvents.length, 0, "Windows baseline capture contains unexplained canary events");
console.log(
  "AC-05 Windows file-access audit passed for both captures; complete descendant coverage remains unverified.",
);
