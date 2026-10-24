import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeWindowsFileTrace,
  inspectWindowsFileTrace,
  verifyWindowsFileTrace,
} from "../../scripts/windows-file-trace.mjs";

const canaryPath = "C:\\Users\\runner\\Temp\\mc-synthetic.png";
const controlPath = "C:\\Users\\runner\\Temp\\mc-control.png";
const header =
  '"Time of Day","Process Name","PID","Operation","Path","Result","Detail"\r\n';
const controlEvent =
  '"10:00:00.0000000","powershell.exe","100","ReadFile","C:\\Users\\runner\\Temp\\mc-control.png","SUCCESS","Offset: 0"\r\n';
const applicationEvents =
  '"10:00:00.0000001","mail-client.exe","200","CreateFile","C:\\app\\mail.db","SUCCESS",""\r\n' +
  '"10:00:00.0000002","msedgewebview2.exe","300","ReadFile","C:\\app\\WebView2Loader.dll","SUCCESS",""\r\n';
const verify = (trace) => verifyWindowsFileTrace(trace, canaryPath, controlPath);

test("AC-05: requires a positive control and observes the app and WebView2", () => {
  assert.deepEqual(verify(header + controlEvent + applicationEvents), {
    positiveControlEvents: 1,
    canaryEvents: 0,
  });
});

test("AC-05: rejects canary access from the app or any other process", () => {
  for (const processName of ["mail-client.exe", "msedgewebview2.exe", "System", "powershell.exe"]) {
    const trace = header + controlEvent + applicationEvents +
      `"10:00:00.0000003","${processName}","400","CreateFile","${canaryPath}","SUCCESS",""\r\n`;
    assert.throws(
      () => verify(trace),
      (error) => {
        assert.match(error.message, /synthetic file canary appeared in 1 unexpected event/);
        assert(!error.message.includes(canaryPath));
        return true;
      },
    );
  }
});

test("AC-05: control-file System events cannot hide attack-canary activity", () => {
  const trace = header + controlEvent + applicationEvents +
    `"10:00:00.0000003","System","4","CreateFileMapping","${controlPath}","SUCCESS",""\r\n`;
  assert.equal(verify(trace).canaryEvents, 0);
  assert.throws(
    () => verify(trace + `"10:00:00.0000004","System","4","WriteFile","${canaryPath}","SUCCESS",""\r\n`),
    /1 unexpected event/,
  );
  assert.throws(
    () => verifyWindowsFileTrace(trace, canaryPath, canaryPath),
    /different file/,
  );
});

test("AC-05: diagnostic inspection records baseline events without granting attack exemptions", () => {
  const trace = header + controlEvent + applicationEvents +
    `"10:00:00.0000003","System","4","CreateFileMapping","${canaryPath}","SUCCESS",""\r\n`;
  const baseline = inspectWindowsFileTrace(trace, canaryPath, controlPath);
  assert.deepEqual(baseline.canaryEvents, [
    { processName: "System", operation: "CreateFileMapping" },
  ]);
  assert.throws(() => verify(trace), /1 unexpected event/);
  assert.throws(
    () => inspectWindowsFileTrace(header + applicationEvents, canaryPath, controlPath),
    /positive control/,
  );
  assert.throws(
    () => inspectWindowsFileTrace(header + controlEvent, canaryPath, controlPath),
    /Tauri application/,
  );
});

test("AC-05: baseline configuration stays separate from the attack suite", async () => {
  const { config: baseline } = await import("../../wdio.file-audit-baseline.conf.mjs");
  const { config: attack } = await import("../../wdio.security.conf.mjs");
  assert.deepEqual(baseline.specs, ["./tests/security/file-audit.baseline.mjs"]);
  assert.deepEqual(attack.specs, ["./tests/security/*.spec.mjs"]);
  assert.equal(baseline.services, attack.services);
});

test("AC-05: rejects unknown CSV layouts and missing positive controls", () => {
  assert.throws(
    () => verify('"Process Name","Path"\r\n'),
    /missing Process Name, Operation, or Path columns/,
  );
  assert.throws(
    () =>
      verify(header + applicationEvents),
    /did not observe the PowerShell synthetic-canary positive control/,
  );
});

test("AC-05: decodes UTF-8 and UTF-16 Process Monitor exports", () => {
  const csv = Buffer.from(header, "utf8");
  const utf16le = Buffer.concat([
    Buffer.from([0xff, 0xfe]),
    Buffer.from(header, "utf16le"),
  ]);
  const utf16be = Buffer.concat([
    Buffer.from([0xfe, 0xff]),
    Buffer.from(header, "utf16le").swap16(),
  ]);

  assert.equal(decodeWindowsFileTrace(csv), header);
  assert.equal(decodeWindowsFileTrace(utf16le), header);
  assert.equal(decodeWindowsFileTrace(utf16be), header);
});
