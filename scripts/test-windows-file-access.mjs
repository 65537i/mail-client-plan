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
import {
  appendBoundedWindowsFilterOutput,
  describeWindowsFilterDiagnostics,
  reloadedFilterUiEvidencePattern,
  windowsFilterOutputLimit,
} from "./windows-filter-diagnostics.mjs";

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
      filterSetupOutput = appendBoundedWindowsFilterOutput(filterSetupOutput, chunk);
    });
    filterSetup.stderr.resume();
    const filterSetupExit = waitForProcess(filterSetup);
    const filterSetupResult = await waitWithTimeout(filterSetupExit, 60_000);
    const outputAtCap = filterSetupOutput.length >= windowsFilterOutputLimit
      ? "; filter-output-at-cap=true"
      : "";
    if (filterSetupResult.timedOut) {
      const filterStage = [...filterSetupOutput.matchAll(
        /PROC_MON_FILTER_PROGRESS=([a-z-]+)/g,
      )].at(-1)?.[1];
      filterSetup.kill();
      await filterSetupExit;
      let cleanupStatus = "passed";
      try {
        await runProcmon(["/AcceptEula", "/Terminate"], "filter setup cleanup");
      } catch {
        cleanupStatus = "failed";
      }
      throw new Error(
        filterStage
          ? `Process Monitor exact-path filter configuration timed out at ${filterStage}${describeWindowsFilterDiagnostics(filterSetupOutput)}; cleanup:${cleanupStatus}${outputAtCap}`
          : `Process Monitor exact-path filter configuration timed out; cleanup:${cleanupStatus}${outputAtCap}`,
      );
    }
    if (filterSetupResult.error) throw new Error("Failed to start Process Monitor filter configuration");
    const filterStage = filterSetupOutput.match(
      /PROC_MON_FILTER_FAILED_STAGE=([a-z-]+)/,
    )?.[1] ?? [...filterSetupOutput.matchAll(
      /PROC_MON_FILTER_PROGRESS=([a-z-]+)/g,
    )].at(-1)?.[1];
    assert.equal(
      filterSetupResult.code,
      0,
      filterStage
        ? `Process Monitor exact-path filter configuration failed at ${filterStage}${describeWindowsFilterDiagnostics(filterSetupOutput)}${outputAtCap}`
        : `Process Monitor exact-path filter configuration failed${outputAtCap}`,
    );
    const filterPathEvidence = describeWindowsFilterDiagnostics(filterSetupOutput)
      .split("; ")
      .find((diagnostic) => diagnostic.startsWith("config-filter-paths="));
    assert(
      filterPathEvidence,
      "Process Monitor exported filter path evidence was not captured",
    );
    console.log(`Windows audit ${scenario}: ${filterPathEvidence}`);
    const reloadedFilterRuleEvidence = describeWindowsFilterDiagnostics(filterSetupOutput)
      .split("; ")
      .find((diagnostic) => diagnostic.startsWith("reloaded-filter-rules="));
    assert.equal(
      reloadedFilterRuleEvidence,
      "reloaded-filter-rules=rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0",
      "Process Monitor did not verify the two exact Include rules after reloading the exported configuration",
    );
    console.log(`Windows audit ${scenario}: ${reloadedFilterRuleEvidence}`);
    const reloadedFilterUiEvidence = describeWindowsFilterDiagnostics(filterSetupOutput)
      .split("; ")
      .find((diagnostic) => diagnostic.startsWith("reloaded-filter-ui="));
    assert.match(
      reloadedFilterUiEvidence ?? "",
      reloadedFilterUiEvidencePattern,
      "Process Monitor did not provide a complete bounded UI snapshot for the reloaded rules",
    );
    console.log(`Windows audit ${scenario}: ${reloadedFilterUiEvidence}`);
    const reloadedDropEvidence = describeWindowsFilterDiagnostics(filterSetupOutput)
      .split("; ")
      .find((diagnostic) => diagnostic.startsWith("reloaded-drop-filtered-events="));
    assert.equal(
      reloadedDropEvidence,
      "reloaded-drop-filtered-events=on",
      "Process Monitor did not verify Drop Filtered Events as enabled after reloading the exported configuration",
    );
    console.log(`Windows audit ${scenario}: ${reloadedDropEvidence}`);
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
        "/LoadConfig",
        filterConfig,
        "/BackingFile",
        backingFile,
      ],
      { stdio: "ignore", windowsHide: false },
    );
    captureExit = waitForProcess(capture);
    assert(capture.pid, "Process Monitor capture process did not start");
    await runProcmon(["/AcceptEula", "/WaitForIdle"], "capture readiness");
    assert.equal(capture.exitCode, null, "Process Monitor capture exited during startup");
    await access(backingFile);
    console.log(`Windows audit ${scenario}: Procmon readiness confirmed UTC=${new Date().toISOString()}`);

    const captureInspection = spawn(
      "powershell.exe",
      [
        "-STA", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", path.join(root, "scripts", "inspect-windows-procmon-capture.ps1"),
        "-OwnerProcessId", String(capture.pid),
      ],
      { stdio: ["ignore", "pipe", "pipe"], windowsHide: true },
    );
    let captureInspectionOutput = "";
    let captureInspectionOverflow = false;
    captureInspection.stdout.setEncoding("utf8");
    captureInspection.stdout.on("data", (chunk) => {
      captureInspectionOverflow ||= captureInspectionOutput.length + chunk.length > 2048;
      captureInspectionOutput = (captureInspectionOutput + chunk).slice(0, 2048);
    });
    captureInspection.stderr.resume();
    const captureInspectionExit = waitForProcess(captureInspection);
    const captureInspectionResult = await waitWithTimeout(captureInspectionExit, 20_000);
    if (captureInspectionResult.timedOut) {
      captureInspection.kill();
      await captureInspectionExit;
      throw new Error("Process Monitor capture inspection timed out");
    }
    const captureInspectionStage = captureInspectionOutput.match(
      /^PROC_MON_CAPTURE_FAILED_STAGE=([a-z-]+)\r?$/m,
    )?.[1];
    assert(
      !captureInspectionResult.error && captureInspectionResult.code === 0 && !captureInspectionOverflow,
      `Process Monitor capture inspection failed${captureInspectionStage ? ` at ${captureInspectionStage}` : ""}`,
    );
    const nativeEvidence = [...captureInspectionOutput.matchAll(
      /^PROC_MON_CAPTURE_NATIVE=children:(0|[1-9]\d{0,2});visible:(0|[1-9]\d{0,2});toolbars:(0|[1-9]\d{0,2});lists:(0|[1-9]\d{0,2});statusbars:(0|[1-9]\d{0,2});dialogs:(0|[1-9]\d{0,2});other:(0|[1-9]\d{0,2})\r?$/gm,
    )];
    assert.equal(nativeEvidence.length, 1, "Process Monitor native child inspection evidence is incomplete");
    const nativeCounts = nativeEvidence[0].slice(1, 8).map(Number);
    assert(
      nativeCounts.every((count) => count <= 256) &&
      nativeCounts[1] <= nativeCounts[0] &&
      nativeCounts.slice(2).reduce((sum, count) => sum + count, 0) === nativeCounts[0],
      "Process Monitor native child inspection counts are inconsistent",
    );
    console.log(`Windows audit ${scenario}: ${nativeEvidence[0][0].trim()}`);
    for (const target of ["capture", "filesystem"]) {
      const msaa = [...captureInspectionOutput.matchAll(
        /^PROC_MON_CAPTURE_MSAA=(capture|filesystem);object:(available|unavailable);items:(0|[1-9]\d?);matches:(0|[1-9]\d?);checked:(unavailable|mixed|on|off);enabled:(unavailable|true|false)\r?$/gm,
      )].filter((match) => match[1] === target);
      assert(
        msaa.length === 1 && Number(msaa[0][3]) <= 64 && Number(msaa[0][4]) <= Number(msaa[0][3]),
        "Process Monitor toolbar MSAA evidence is incomplete",
      );
      console.log(`Windows audit ${scenario}: ${msaa[0][0].trim()}`);
    }
    const windowEvidence = [...captureInspectionOutput.matchAll(
      /^PROC_MON_CAPTURE_WINDOW=visual:(unavailable|normal|minimized|maximized);enabled:(true|false);offscreen:(true|false);items:(0|[1-9]\d{0,2});toolbars:(0|[1-9]\d{0,2});buttons:(0|[1-9]\d{0,2});menuitems:(0|[1-9]\d{0,2})\r?$/gm,
    )];
    assert(
      windowEvidence.length === 1 && windowEvidence[0].slice(4, 8).every((count) => Number(count) <= 256),
      "Process Monitor capture window inspection evidence is incomplete",
    );
    console.log(`Windows audit ${scenario}: ${windowEvidence[0][0].trim()}`);
    const contextEvidence = [...captureInspectionOutput.matchAll(
      /^PROC_MON_CAPTURE_CONTEXT=class:(dialog|other);modal:(unavailable|true|false);texts:(0|[1-9]\d{0,2});startup-error:(none|multiple|requires-64-bit|already-monitoring|requires-admin|driver-version-conflict|driver-load|enable-capture|config-open)\r?$/gm,
    )];
    assert(
      contextEvidence.length === 1 && Number(contextEvidence[0][3]) <= 256,
      "Process Monitor capture context inspection evidence is incomplete",
    );
    console.log(`Windows audit ${scenario}: ${contextEvidence[0][0].trim()}`);
    assert.equal(contextEvidence[0][4], "none", "Process Monitor reported a known capture startup error");
    for (const target of ["capture", "filesystem"]) {
      const evidence = [...captureInspectionOutput.matchAll(
        /^PROC_MON_CAPTURE_CONTROL=(capture|filesystem);matches:(0|[1-9]\d{0,2});toggle:(unavailable|on|off|mixed);selected:(unavailable|on|off);enabled:(unavailable|true|false);offscreen:(unavailable|true|false)\r?$/gm,
      )].filter((match) => match[1] === target && Number(match[2]) <= 256);
      assert.equal(evidence.length, 1, "Process Monitor capture inspection evidence is incomplete");
      console.log(`Windows audit ${scenario}: ${evidence[0][0].trim()}`);
    }
    assert.equal(capture.exitCode, null, "Process Monitor capture exited during inspection");

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
    console.log(`Windows audit ${scenario}: positive-control read completed UTC=${new Date().toISOString()}`);
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
    console.log(`Windows audit ${scenario}: excluded-control read completed UTC=${new Date().toISOString()}`);

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
      ["/AcceptEula", "/Quiet", "/NoFilter", "/OpenLog", backingFile, "/SaveAs", csvFile],
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
