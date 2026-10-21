import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { nativeCiPlan } from "../../scripts/native-ci-plan.mjs";

const targets = ["ubuntu-24.04-x64", "windows-2025-x64", "macos-14-arm64", "macos-15-intel"];
const modes = ["basic", "webview", "full"];

test("native CI: pushes run basic Linux checks and PRs retain full cross-OS validation", () => {
  assert.deepEqual(nativeCiPlan("push"), {
    matrix: { include: [{ platform: targets[0], runner: "ubuntu-24.04" }] },
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
      for (const item of plan.matrix.include) assert.equal(typeof item.runner, "string");
    }
  }
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
        CI_TARGET: "macos-14-arm64",
        CI_MODE: "webview",
        GITHUB_OUTPUT: output,
        GITHUB_STEP_SUMMARY: summary,
      },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);
    const lines = (await readFile(output, "utf8")).trim().split("\n");
    assert.deepEqual(JSON.parse(lines[0].slice("matrix=".length)), {
      include: [{ platform: "macos-14-arm64", runner: "macos-14" }],
    });
    assert.equal(lines[1], "mode=webview");
    assert.match(await readFile(summary, "utf8"), /Partial validation only/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
