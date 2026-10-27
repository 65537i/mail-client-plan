import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createWindowsAuditCanary } from "../../scripts/windows-audit-canary.mjs";

test("AC-05: capture window visibility is observable without restoring or toggling controls", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.doesNotMatch(driver, /"\/Minimized"/);
  assert.match(driver, /capture = spawn\([\s\S]*windowsHide: false/);
  assert.match(inspection, /WindowPattern\]::Pattern/);
  assert.match(inspection, /windowPattern.Current.WindowVisualState/);
  assert.match(inspection, /PROC_MON_CAPTURE_WINDOW=visual:\$visual/);
  assert.match(inspection, /\$child = \$walker.GetNextSibling\(\$child\)\s*\}\s*\}\s*\[Console\]::Out.WriteLine\(\s*"PROC_MON_CAPTURE_WINDOW=/);
  assert.doesNotMatch(inspection, /SetWindowVisualState|ShowWindow/);
  assert.match(driver, /windowEvidence.length === 1/);
  assert.match(driver, /slice\(4, 8\).every\(\(count\) => Number\(count\) <= 256\)/);
});

test("AC-05: capture inspection is bounded, read-only and precedes control reads", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /GetProcessById\(\$OwnerProcessId\)/);
  assert.match(inspection, /\$state.ProcessId -ne \$OwnerProcessId/);
  assert.match(inspection, /\$visited \+ \$pending.Count -ge 256/);
  assert.match(inspection, /switch -CaseSensitive \(\$label\)/);
  assert.match(inspection, /TogglePattern\]::Pattern/);
  assert.match(inspection, /SelectionItemPattern\]::Pattern/);
  assert.match(inspection, /\$toggle = "unavailable"/);
  assert.match(inspection, /PROC_MON_CAPTURE_FAILED_STAGE=\$stage/);
  assert.doesNotMatch(inspection, /Invoke\(|Toggle\(|Select\(|SendKeys|SetFocus|SetForegroundWindow|WriteLine\([^)]*(?:Name|Exception)/);
  assert.match(driver, /capture readiness[\s\S]*inspect-windows-procmon-capture.ps1[\s\S]*captureInspectionExit, 20_000[\s\S]*captureInspectionOverflow[\s\S]*evidence.length, 1[\s\S]*const positiveControl = spawn/);
  assert.match(driver, /slice\(0, 2048\)/);
});

test("AC-05: capture readiness precedes both controls and WDIO without a fixed startup delay", async () => {
  const source = await readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8");
  assert.match(
    source,
    /captureExit = waitForProcess\(capture\);[\s\S]*await runProcmon\(\["\/AcceptEula", "\/WaitForIdle"\], "capture readiness"\);[\s\S]*assert.equal\(capture.exitCode, null,[\s\S]*await access\(backingFile\);[\s\S]*const positiveControl = spawn\([\s\S]*positiveControlResult.code,[\s\S]*const excludedControl = spawn\([\s\S]*excludedControlResult.code,[\s\S]*command.send\("start"\)/,
  );
  assert.doesNotMatch(source, /setTimeout\(resolve, 1500\)/);
  assert.match(source, /waitWithTimeout\(childExit, 20_000\)/);
  assert.match(source, /child.kill\(\);[\s\S]*throw new Error\(`Process Monitor \$\{description\} timed out`\)/);
});

test("AC-05: write-through canary preserves content, closes, and refuses overwrite", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "mc-canary-test-"));
  const filePath = path.join(directory, "canary.png");
  try {
    const bytes = await createWindowsAuditCanary(filePath);
    assert.equal(bytes, Buffer.byteLength("Synthetic file-access canary; no user data.\n"));
    assert.equal((await stat(filePath)).size, bytes);
    assert.equal(await readFile(filePath, "utf8"), "Synthetic file-access canary; no user data.\n");
    await assert.rejects(createWindowsAuditCanary(filePath), { code: "EEXIST" });
    assert.equal(await readFile(filePath, "utf8"), "Synthetic file-access canary; no user data.\n");
    await unlink(filePath);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("AC-05: canary creation errors propagate without a buffered fallback", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "mc-canary-test-"));
  try {
    await assert.rejects(
      createWindowsAuditCanary(path.join(directory, "missing", "canary.png")),
      { code: "ENOENT" },
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
