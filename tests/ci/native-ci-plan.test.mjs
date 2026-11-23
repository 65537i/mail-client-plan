import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { nativeCiPlan } from "../../scripts/native-ci-plan.mjs";

const targets = [
  "ubuntu-24.04-x64",
  "ubuntu-24.04-arm64",
  "windows-2025-x64",
  "windows-11-arm64",
  "macos-15-intel",
  "macos-15-arm64",
];
const modes = ["basic", "webview", "full"];

test("native CI: pushes run basic Linux checks and PRs retain full cross-OS validation", () => {
  assert.deepEqual(nativeCiPlan("push"), {
    matrix: { include: [{ platform: targets[0], runner: "ubuntu-24.04", arch: "x64" }] },
    mode: "basic",
  });
  const plan = nativeCiPlan("pull_request");
  assert.equal(plan.mode, "full");
  assert.deepEqual(plan.matrix.include.map((item) => item.platform), targets);
});

test("native CI: every manual target and mode produces the exact requested matrix", () => {
  for (const target of ["all", ...targets]) {
    for (const mode of modes) {
      const plan = nativeCiPlan("workflow_dispatch", target, mode);
      assert.equal(plan.mode, mode);
      assert.deepEqual(plan.matrix.include.map((item) => item.platform), target === "all" ? targets : [target]);
      for (const item of plan.matrix.include) {
        assert.equal(typeof item.runner, "string");
        assert(["x64", "arm64"].includes(item.arch));
      }
    }
  }
});

test("native CI: Windows ARM uses the ARM Process Monitor executable", async () => {
  const workflow = await readFile(
    new URL("../../.github/workflows/native.yml", import.meta.url),
    "utf8",
  );
  assert.match(workflow, /\$procmonName = if \("\$\{\{ matrix\.arch \}\}" -eq "arm64"\) \{ "Procmon64a\.exe" \} else \{ "Procmon64\.exe" \}/);
  assert.match(workflow, /ubuntu-24\.04-arm64[\s\S]*windows-11-arm64[\s\S]*macos-15-arm64/);
});

test("native CI: rejects unsupported events and inputs rather than silently running a fallback", () => {
  for (const args of [
    ["schedule"], ["push", "all", "full"], ["pull_request", "", "basic"],
    ["workflow_dispatch", "", ""], ["workflow_dispatch", "other", "full"],
    ["workflow_dispatch", "all", "other"],
  ]) {
    assert.throws(() => nativeCiPlan(...args));
  }
});

test("native CI: CLI writes valid matrix outputs and an explicit partial-validation summary", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "native-ci-plan-"));
  try {
    const output = path.join(directory, "output");
    const summary = path.join(directory, "summary");
    const result = spawnSync(process.execPath, [
      fileURLToPath(new URL("../../scripts/native-ci-plan.mjs", import.meta.url)),
    ], {
      env: {
        ...process.env,
        CI_EVENT: "workflow_dispatch",
        CI_TARGET: "macos-15-arm64",
        CI_MODE: "webview",
        GITHUB_OUTPUT: output,
        GITHUB_STEP_SUMMARY: summary,
      },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    const lines = (await readFile(output, "utf8")).trim().split("\n");
    assert.deepEqual(JSON.parse(lines[0].slice("matrix=".length)), {
      include: [{ platform: "macos-15-arm64", runner: "macos-15", arch: "arm64" }],
    });
    assert.equal(lines[1], "mode=webview");
    assert.match(await readFile(summary, "utf8"), /Partial validation only/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
