import assert from "node:assert/strict";
import test from "node:test";
import {
  decodeWindowsFileTrace,
  inspectWindowsFileTrace,
  summarizeWindowsFileTrace,
  verifyWindowsFileTrace,
} from "../../scripts/windows-file-trace.mjs";

const canaryPath = "C:\\Users\\runner\\Temp\\mc-synthetic.png";
const controlPath = "C:\\Users\\runner\\Temp\\mc-control.png";
const excludedPath = "C:\\Users\\runner\\Temp\\mc-excluded.png";
const header =
  '"Time of Day","Process Name","PID","Operation","Path","Result","Detail"\r\n';
const controlEvent =
  '"10:00:00.0000000","node.exe","100","ReadFile","C:\\Users\\runner\\Temp\\mc-control.png","SUCCESS","Offset: 0"\r\n';
const verify = (trace) => verifyWindowsFileTrace(trace, canaryPath, controlPath, excludedPath);

test("AC-05: requires the exact-path positive control", () => {
  assert.deepEqual(verify(header + controlEvent), {
    positiveControlEvents: 1,
    canaryEvents: 0,
  });
});

test("AC-05: rejects canary access from any process", () => {
  for (const processName of ["mail-client.exe", "msedgewebview2.exe", "System", "powershell.exe", "node.exe"]) {
    const trace = header + controlEvent +
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
  const trace = header + controlEvent +
    `"10:00:00.0000003","System","4","CreateFileMapping","${controlPath}","SUCCESS",""\r\n`;
  assert.equal(verify(trace).canaryEvents, 0);
  assert.throws(
    () => verify(trace + `"10:00:00.0000004","System","4","WriteFile","${canaryPath}","SUCCESS",""\r\n`),
    /1 unexpected event/,
  );
  assert.throws(
    () => verifyWindowsFileTrace(trace, canaryPath, canaryPath, excludedPath),
    /different file/,
  );
});

test("AC-05: diagnostic inspection records baseline events without granting attack exemptions", () => {
  const trace = header + controlEvent +
    `"10:00:00.0000003","System","4","CreateFileMapping","${canaryPath}","SUCCESS",""\r\n`;
  const baseline = inspectWindowsFileTrace(trace, canaryPath, controlPath, excludedPath);
  assert.deepEqual(baseline.canaryEvents, [
    { processName: "System", operation: "CreateFileMapping" },
  ]);
  assert.throws(() => verify(trace), /1 unexpected event/);
  assert.throws(
    () => inspectWindowsFileTrace(header, canaryPath, controlPath, excludedPath),
    /positive control/,
  );
  assert.throws(
    () => inspectWindowsFileTrace(
      header + controlEvent + `"10:00:00.0000001","System","4","ReadFile","C:\\other\\unrelated.txt","SUCCESS",""\r\n`,
      canaryPath,
      controlPath,
      excludedPath,
    ),
    /outside the exact canary and control paths/,
  );
  assert.throws(
    () => inspectWindowsFileTrace(
      header + controlEvent +
        `"10:00:00.0000002","node.exe","100","ReadFile","${excludedPath}","SUCCESS",""\r\n`,
      canaryPath,
      controlPath,
      excludedPath,
    ),
    /outside the exact canary and control paths/,
  );
  assert.throws(
    () => inspectWindowsFileTrace(
      header + controlEvent +
        '"10:00:00.0000002","node.exe","100","ReadFile","C:\\Users\\runner\\Other\\mc-synthetic.png","SUCCESS",""\r\n',
      canaryPath,
      controlPath,
      excludedPath,
    ),
    /outside the exact canary and control paths/,
  );
  assert.throws(
    () => inspectWindowsFileTrace(header + controlEvent, canaryPath, controlPath),
    /paths are required/,
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
    () => verify(header),
    /did not observe the Node synthetic-canary positive control/,
  );
});

test("AC-05: requires an exact Node ReadFile control, not a lookalike or metadata event", () => {
  for (const event of [
    controlEvent.replace("node.exe", "powershell.exe"),
    controlEvent.replace("node.exe", "not-node.exe"),
    controlEvent.replace("ReadFile", "CreateFile"),
  ]) {
    assert.throws(() => verify(header + event), /positive control/);
  }
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

test("AC-05: canary diagnostics expose only bounded allowlisted metadata", () => {
  const event = `"10:02:03.1234567","System","4","CreateFileMapping","${canaryPath}","SUCCESS","SyncType: SyncTypeCreateSection, PageProtection: PAGE_READONLY, Offset: 0, Length: 42, File: C:\\private\\secret, Token: synthetic-secret"\r\n`;
  const summary = summarizeWindowsFileTrace(header + event.repeat(12), canaryPath);
  assert.equal(summary.canaryEvents.length, 12);
  assert.equal(summary.canaryDiagnostics.length, 10);
  assert.deepEqual(summary.canaryDiagnostics[0], {
    time: "10:02:03.1234567",
    processName: "System",
    operation: "CreateFileMapping",
    result: "SUCCESS",
    detail: {
      fields: ["SyncType: SyncTypeCreateSection", "PageProtection: PAGE_READONLY", "Offset: 0", "Length: 42"],
      redactedFields: 2,
    },
  });
  const diagnostic = JSON.stringify(summary.canaryDiagnostics);
  assert(!diagnostic.includes("private"));
  assert(!diagnostic.includes("synthetic-secret"));
  assert(!diagnostic.includes(canaryPath));
  assert.throws(() => verify(header + controlEvent + event), /1 unexpected event/);
});

test("AC-05: malformed rows fail rather than hiding canary events", () => {
  assert.throws(() => verify(header + controlEvent + '"truncated"\r\n'), /column count/);
});

test("AC-05: unknown diagnostic formats are redacted without dropping the event", () => {
  const event = `"secret-time","C:\\private\\process","4","ReadFile","${canaryPath}","C:\\private\\result","Offset: secret, Length: -1"\r\n`;
  const summary = summarizeWindowsFileTrace(header + event, canaryPath);
  assert.equal(summary.canaryEvents.length, 1);
  assert.deepEqual(summary.canaryDiagnostics[0], {
    time: "[unavailable]",
    processName: "[redacted]",
    operation: "ReadFile",
    result: "[redacted]",
    detail: { fields: [], redactedFields: 2 },
  });
});
