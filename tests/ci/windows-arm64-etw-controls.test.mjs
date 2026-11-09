import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const workflow = (await readFile(
  new URL("../../.github/workflows/windows-arm64-etw-controls.yml", import.meta.url), "utf8",
)).replaceAll("\r\n", "\n");

test("ETW hosted PoC: manual-only hosted ARM64 routing and immutable checkout", () => {
  assert.match(workflow, /on:\n  workflow_dispatch:\n\npermissions:\n  contents: read/);
  assert.match(workflow, /runs-on: windows-11-arm/);
  assert.match(workflow, /timeout-minutes: 10/);
  assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /actions\/checkout@[a-f0-9]{40}[\s\S]*ref: \$\{\{ github.sha \}\}\n          persist-credentials: false/);
  const expression = workflow.match(/    if: (.+)/)?.[1];
  assert.ok(expression);
  for (const event of ["workflow_dispatch", "push", "pull_request"]) {
    for (const repository of ["65537i/mail-client-plan", "other/repository"]) {
      assert.equal(vm.runInNewContext(expression, {
        github: { event_name: event, repository },
      }), event === "workflow_dispatch" && repository === "65537i/mail-client-plan");
    }
  }
  assert.doesNotMatch(workflow, /self-hosted|secrets\.|upload-artifact|actions\/cache|continue-on-error/);
});

test("ETW hosted PoC: real controls and native prerequisites cannot be skipped or substituted", () => {
  assert.match(workflow, /RUNNER_ARCH -cne "ARM64"[\s\S]*ProcessArchitecture[\s\S]*Administrator/);
  assert.match(workflow, /Microsoft.VisualStudio.Component.VC.Tools.ARM64/);
  assert.match(workflow, /VC\\Auxiliary\\Build\\vcvarsall.bat/);
  assert.equal(workflow.match(/call "\{0\}" arm64 >nul && powershell.exe/g)?.length, 2);
  assert.equal(workflow.match(/-Capture -Scenario untouched/g)?.length, 1);
  assert.equal(workflow.match(/-Capture -Scenario touched/g)?.length, 1);
  assert.ok(workflow.indexOf("-Scenario untouched") < workflow.indexOf("-Scenario touched"));
  assert.match(workflow, /node --test tests\/security\/windows-etw-controls.test.mjs/);
  assert.doesNotMatch(workflow, /tauri build|test:security:file-access:windows|wpr.exe|tracerpt|\.etl/);
});

test("ETW hosted PoC: cleanup reports failures without stopping unrelated sessions", () => {
  const cleanup = workflow.slice(workflow.indexOf("- name: Verify session and fixture cleanup"));
  assert.match(cleanup, /if: \$\{\{ !cancelled\(\) \}\}/);
  assert.match(cleanup, /logman.exe query "MailClient-EtwControls-PoC" -ets/);
  assert.match(cleanup, /LASTEXITCODE -ne -2144337918/);
  assert.match(cleanup, /mail-client-etw-build-\*/);
  assert.match(cleanup, /mail-client-etw-controls-\*/);
  assert.doesNotMatch(workflow, /logman.exe (?:stop|delete)|Stop-Process|Remove-Item|exit 0/);
  assert.match(cleanup, /no real WebView or AC-05 completion is claimed/);
});
