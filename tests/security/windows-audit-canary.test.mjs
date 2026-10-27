import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createWindowsAuditCanary } from "../../scripts/windows-audit-canary.mjs";

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
