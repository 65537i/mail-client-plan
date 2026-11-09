import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { runInNewContext } from "node:vm";

const sourceSha = "182557978df3afb0a4f5077946ba76564dcd7422";
const workflowUrl = new URL("../../.github/workflows/windows-arm64-interactive.yml", import.meta.url);
async function readWorkflow() {
  return (await readFile(workflowUrl, "utf8")).replace(/\r\n/g, "\n");
}

test("interactive ARM64 CI: manual opt-in and fixed source authorization precede runner selection", async () => {
  const workflow = await readWorkflow();
  assert.match(workflow, /\non:\n  workflow_dispatch:\n/);
  assert.doesNotMatch(workflow, /\n  (?:push|pull_request|pull_request_target|workflow_call|schedule):/);
  assert.match(workflow, /default: false\n        type: boolean/);
  const gate = workflow.slice(workflow.indexOf("    if: >-"), workflow.indexOf("    runs-on:"));
  for (const condition of [
    "github.event_name == 'workflow_dispatch'",
    "github.repository == '65537i/mail-client-plan'",
    "inputs.isolated_runner_approved == true",
    `inputs.approved_sha == '${sourceSha}'`,
    `vars.MAIL_CLIENT_INTERACTIVE_APPROVED_SHA == '${sourceSha}'`,
  ]) {
    assert.ok(gate.includes(condition), condition);
  }
  const expression = gate.slice(gate.indexOf(">-") + 2).trim();
  const approvedContext = {
    github: { event_name: "workflow_dispatch", repository: "65537i/mail-client-plan" },
    inputs: { isolated_runner_approved: true, approved_sha: sourceSha },
    vars: { MAIL_CLIENT_INTERACTIVE_APPROVED_SHA: sourceSha },
  };
  assert.equal(runInNewContext(expression, structuredClone(approvedContext)), true);
  for (const [section, key, value] of [
    ["github", "event_name", "pull_request"],
    ["github", "event_name", "push"],
    ["github", "repository", "untrusted/fork"],
    ["inputs", "isolated_runner_approved", false],
    ["inputs", "approved_sha", "main"],
    ["inputs", "approved_sha", "0".repeat(40)],
    ["vars", "MAIL_CLIENT_INTERACTIVE_APPROVED_SHA", undefined],
    ["vars", "MAIL_CLIENT_INTERACTIVE_APPROVED_SHA", "0".repeat(40)],
  ]) {
    const context = structuredClone(approvedContext);
    context[section][key] = value;
    assert.equal(runInNewContext(expression, context), false, `${section}.${key}=${value}`);
  }
  assert.match(workflow, /runs-on: \[self-hosted, Windows, ARM64, mail-client-isolated-interactive\]/);
  assert.match(workflow, /concurrency:\n  group: windows-arm64-interactive-audit\n  cancel-in-progress: false/);
  assert.match(workflow, /timeout-minutes: 45/);
});

test("interactive ARM64 CI: checkout is immutable and credentials, secrets, and uploads stay out", async () => {
  const workflow = await readWorkflow();
  assert.ok(workflow.includes(`ref: ${sourceSha}\n          persist-credentials: false`));
  assert.ok(workflow.includes(`APPROVED_SOURCE_SHA: ${sourceSha}`));
  assert.match(workflow, /permissions:\n  contents: read\n/);
  for (const action of workflow.matchAll(/uses: ([^\s]+)/g)) {
    assert.match(action[1], /^actions\/checkout@[0-9a-f]{40}$/);
  }
  assert.doesNotMatch(workflow, /secrets\.|secrets:|write-all|contents: write|upload-artifact|actions\/cache|inputs\.approved_sha\s*\}\}/);
  assert.match(workflow, /\$actual -cne \$env:APPROVED_SOURCE_SHA/);
  assert.match(workflow, /Partial validation only: not hosted-runner/);
  assert.match(workflow, /CAPTURE_OUTCOME: \$\{\{ steps\.capture\.outcome \}\}/);
});

test("interactive ARM64 CI: preflight fails closed and the existing real audit remains mandatory", async () => {
  const workflow = await readWorkflow();
  assert.ok(workflow.indexOf("Verify isolated interactive ARM64 prerequisites") < workflow.indexOf("uses: actions/checkout"));
  for (const required of [
    "[Environment]::UserInteractive",
    "WindowsBuiltInRole]::Administrator",
    "Existing Procmon prevents isolated audit",
    "$env:CARGO_TARGET_DIR -or $env:CARGO_BUILD_TARGET",
    "$env:MAIL_CLIENT_WDIO_BINARY",
    "Get-AuthenticodeSignature",
    "Procmon64a.exe",
    "Pinned Node is required",
    "Native ARM64 Node is required",
    "Pinned pnpm is required",
    "host: aarch64-pc-windows-msvc",
    "pnpm install --frozen-lockfile",
    "pnpm exec tauri build --no-bundle --ci --features security-test",
    "windows-audit-canary.test.mjs",
    "windows-audit-wdio.test.mjs",
    "windows-filter-diagnostics.test.mjs",
    "windows-file-trace.test.mjs",
    ".\\tests\\security\\windows-filter-export.test.ps1",
    "pnpm run test:security:file-access:windows",
    'MAIL_CLIENT_REQUIRE_SECRET_STORE: "1"',
  ]) {
    assert.ok(workflow.includes(required), required);
  }
  assert.doesNotMatch(workflow, /continue-on-error|Stop-Process|SetForegroundWindow|SwitchDesktop|--token|config\.cmd|run\.cmd/);
});
