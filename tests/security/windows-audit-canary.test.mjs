import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, unlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createWindowsAuditCanary } from "../../scripts/windows-audit-canary.mjs";

test("AC-05: SCM driver inventory is bounded and identifies Procmon by service name or image path", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /Get-CimInstance -ClassName Win32_SystemDriver[\s\S]*PathName, State, Started, ServiceType, ExitCode -OperationTimeoutSec 5 \|\s*Select-Object -First 1025/);
  assert.match(inspection, /\$Drivers.Count -gt 1024/);
  assert.match(inspection, /\$driver.Name -match '\^PROCMON\[0-9\]\*\$'/);
  assert.match(inspection, /\$imagePath -match/);
  assert.match(inspection, /procmon/);
  assert.match(inspection, /\\.sys/);
  assert.match(inspection, /if \(-not \$nameMatch -and -not \$imageMatch\) \{ continue \}/);
  assert.match(inspection, /\$driver.Started -isnot \[bool\]/);
  assert.match(inspection, /\$driver.ExitCode -isnot \[uint32\]/);
  assert.match(inspection, /if \(\$CountOnly\) \{ exit 0 \}[\s\S]*query-system-driver-inventory[\s\S]*classify-system-driver-inventory/);
  assert.match(inspection, /WindowsPrincipal\]::new\(\$identity\)[\s\S]*WindowsBuiltInRole\]::Administrator[\s\S]*PROC_MON_CAPTURE_ADMINISTRATOR/);
  assert.doesNotMatch(inspection, /Start-Service|Stop-Service|Set-Service|Invoke-CimMethod|WriteLine\([^)]*driver\.(Name|PathName|State)/);
  assert.match(inspection, /PROC_MON_CAPTURE_FAILURE=\$failureType/);
  assert.match(inspection, /"CimException"[\s\S]*"ManagementException"[\s\S]*"InvalidOperationException"[\s\S]*"ParameterBindingException"[\s\S]*"RuntimeException"/);
  assert.match(driver, /captureInspectionFailure[\s\S]*Process Monitor capture inspection failed/);
  assert.match(driver, /driverEvidence.length === 1[\s\S]*Number\(driverEvidence\[0\]\[1\]\) <= 1024/);
  assert.match(driver, /slice\(2, 9\).every\(\(count\) => Number\(count\) <= Number\(driverEvidence\[0\]\[1\]\)\)/);
});

test("AC-05: driver registry inspection is read-only, bounded and emits aggregate counts only", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /RegistryHive\]::LocalMachine[\s\S]*RegistryView\]::Registry64/);
  assert.match(inspection, /SYSTEM\\CurrentControlSet\\Services/);
  assert.match(inspection, /\$serviceNames = \$ServicesRoot\.GetSubKeyNames\(\)/);
  assert.match(inspection, /\$serviceNames.Count -gt 4096/);
  assert.match(inspection, /\$serviceNames \| Where-Object \{ \$_ -match '\(\?i\)procmon' \}/);
  assert.match(inspection, /\$candidates.Count -gt 64/);
  assert.match(inspection, /\$candidate -match '\^PROCMON\[0-9\]\*\$'/);
  assert.match(inspection, /GetValue\(\s*"ImagePath", \$null, \[Microsoft\.Win32\.RegistryValueOptions\]::DoNotExpandEnvironmentNames/);
  assert.match(inspection, /\$key.GetValueNames\(\)[\s\S]*-ccontains "Type"[\s\S]*-ccontains "Start"[\s\S]*-ccontains "Parameters"/);
  assert.match(inspection, /\$valueNames.Count -gt 128 -or \$subKeyNames.Count -gt 128/);
  assert.match(inspection, /finally \{\s*\$key\.Dispose\(\)/);
  assert.match(inspection, /PROC_MON_CAPTURE_DRIVER_REGISTRY=\$\(\$registryInventory\.Evidence\)/);
  assert.doesNotMatch(inspection, /SetValue\(|DeleteValue\(|DeleteSubKey|WriteLine\([^)]*(?:PSChildName|imagePath|expandedPath)/);
  assert.match(driver, /registryEvidence.length === 1[\s\S]*Number\(registryEvidence\[0\]\[1\]\) <= 4096[\s\S]*slice\(3, 12\)/);
  assert.match(inspection, /Get-Service -Name \$name -ErrorAction Stop/);
  assert.match(inspection, /NoServiceFoundForGivenName,\*/);
  assert.match(inspection, /PROC_MON_CAPTURE_SERVICE_STATUS=\$serviceEvidence/);
  assert.match(driver, /serviceEvidence.length === 1[\s\S]*Number\(serviceEvidence\[0\]\[2\]\) \+ Number\(serviceEvidence\[0\]\[3\]\) === Number\(serviceEvidence\[0\]\[1\]\)/);
  assert.match(driver, /slice\(3, 12\)\.every/);
  assert.doesNotMatch(inspection, /WriteLine\([^)]*\$name/);
  assert.match(driver, /DRIVER_REGISTRY=keys:\(0\|\[1-9\]\\d\{0,3\}\);candidates:/);
});

test("AC-05: Filter Manager inventory is an independent bounded read-only driver observation", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /System32\\fltmc\.exe[\s\S]*\$filterManagerPath filters/);
  assert.match(inspection, /Get-ProcmonFilterManagerEvidence[\s\S]*Lines\.Count -gt 256/);
  assert.match(inspection, /if \(\$line -notmatch '\^\\s\*\(\?i:PROCMON\)'\) \{ continue \}/);
  assert.match(inspection, /Procmon Filter Manager candidate has an unsupported shape/);
  assert.match(inspection, /GetVolumePathName[\s\S]*\$filterManagerPath instances -v \$volumeName 2>\$null/);
  assert.match(inspection, /Get-ProcmonFilterManagerVolumeEvidence[\s\S]*SprtFtrs[\s\S]*\$instanceCount -gt 64/);
  assert.match(inspection, /instance-list-header[\s\S]*volume-heading[\s\S]*instances-heading[\s\S]*instance-heading[\s\S]*filter-manager-heading[\s\S]*filter-heading[\s\S]*unexpected-preamble[\s\S]*separator-shape[\s\S]*row-shape[\s\S]*PROC_MON_CAPTURE_FILTER_MANAGER_PARSE=\$script:filterManagerVolumeParseState/);
  assert.match(inspection, /\$script:stage = "query-filter-manager-filter-inventory"[\s\S]*\$script:stage = "resolve-filter-manager-target-volume"[\s\S]*\$script:stage = "query-filter-manager-instance-command"[\s\S]*\$script:stage = "parse-filter-manager-instance-output"/);
  assert.match(inspection, /\$script:filterManagerInstanceQueryExitCode = \$null[\s\S]*instances -v \$volumeName 2>\$null[\s\S]*\$script:filterManagerInstanceQueryExitCode = \$LASTEXITCODE[\s\S]*Get-ProcmonFilterManagerVolumeEvidence \$instanceLines[\s\S]*PROC_MON_CAPTURE_FILTER_MANAGER_COMMAND=exit-code:\$queryExitCode/);
  assert.doesNotMatch(inspection, /instances -f \$candidateName -v/);
  assert.match(inspection, /target-volume-attached:\$attached;target-volume-instances:\$targetVolumeInstances/);
  assert.match(inspection, /PROC_MON_CAPTURE_FILTER_MANAGER=\$filterManagerEvidence/);
  assert.doesNotMatch(inspection, /fltmc\.exe\s+(?:load|unload|attach|detach)|WriteLine\([^)]*(?:\$line|\$filterManagerPath|\$volumeName|\$candidateName)/i);
  assert.match(driver, /"-OwnerProcessId", String\(capture\.pid\), "-TargetPath", canaryPath/);
  assert.match(driver, /PROC_MON_CAPTURE_FILTER_MANAGER_COMMAND=exit-code:\(0\|\[1-9\]\\d\{0,2\}\|out-of-range\)/);
  assert.match(driver, /PROC_MON_CAPTURE_FILTER_MANAGER_PARSE=\(started\|empty-output\|line-limit\|line-shape\|duplicate-header\|instance-list-header\|volume-heading\|instances-heading\|instance-heading\|filter-manager-heading\|filter-heading\|unexpected-preamble\|separator-shape\|row-shape\|invalid-count\|count-limit\|inventory-limit\|incomplete-table\|valid\)/);
  assert.match(driver, /Filter Manager parse state \$\{filterManagerParseState\}/);
  assert.match(driver, /FILTER_MANAGER=candidates:\(0\|\[1-9\]\\d\{0,2\}\);instances:\(0\|\[1-9\]\\d\{0,4\}\);target-volume-attached:\(true\|false\);target-volume-instances:/);
  assert.match(driver, /filterManagerEvidence.length === 1[\s\S]*Number\(filterManagerEvidence\[0\]\[1\]\) <= 64/);
  assert.match(driver, /Number\(filterManagerEvidence\[0\]\[4\]\) <= Number\(filterManagerEvidence\[0\]\[1\]\) \* 64/);
});

test("AC-05: live filter verification attaches to the capture PID and preserves its lifetime", async () => {
  const [configuration, driver] = await Promise.all([
    readFile(new URL("../../scripts/configure-windows-procmon-filter.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(configuration, /GetProcessById\(\$CaptureProcessId\)/);
  assert.match(configuration, /\$process.Path -cne \[IO.Path\]::GetFullPath\(\$ProcmonPath\)/);
  assert.match(configuration, /if \(-not \$PSBoundParameters.ContainsKey\("CaptureProcessId"\)\) \{\s*Set-Stage "wait-for-input-idle"/);
  assert.match(configuration, /if \(-not \$PSBoundParameters.ContainsKey\("CaptureProcessId"\) -and -not \$process.HasExited\)/);
  assert.match(configuration, /reloaded-filter-rules-verified"[\s\S]*PROC_MON_FILTER_LIVE_VERIFIED=rules:exact-two;drop:on/);
  assert.match(driver, /async function verifyLiveCaptureFilter\(label\)[\s\S]*"-CaptureProcessId", String\(capture\.pid\)[\s\S]*liveFilterExit, 30_000[\s\S]*PROC_MON_FILTER_LIVE_VERIFIED=rules:exact-two;drop:on/);
  assert.match(driver, /await verifyLiveCaptureFilter\("before-controls"\)[\s\S]*const positiveControl = spawn/);
  assert.match(driver, /await readCaptureListCount\("after-controls", true\)[\s\S]*command\.send\("start"\)/);
  assert.match(driver, /positive-control read completed[\s\S]*await readCaptureListCount\("after-positive-control", true\)[\s\S]*const excludedControl = spawn/);
  assert.match(driver, /const alternateControl = spawn\(\s*"powershell\.exe"[\s\S]*\[System\.IO\.File\]::ReadAllBytes\(\$env:MAIL_CLIENT_FILE_CANARY\)[\s\S]*MAIL_CLIENT_FILE_CANARY: positiveControlPath[\s\S]*await readCaptureListCount\("after-alternate-control", true\)[\s\S]*const excludedControl = spawn/);
  assert.match(driver, /WDIO finished[\s\S]*await verifyLiveCaptureFilter\("after-wdio"\)[\s\S]*await readCaptureListCount\("final"\)/);
});

test("AC-05: only offline export clears display filters and all exported paths remain validated", async () => {
  const source = await readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8");
  assert.equal((source.match(/"\/NoFilter"/g) ?? []).length, 1);
  assert.match(source, /\["\/AcceptEula", "\/Quiet", "\/NoFilter", "\/OpenLog", backingFile, "\/SaveAs", csvFile\]/);
  assert.match(source, /capture = spawn\([\s\S]*"\/LoadConfig",\s*filterConfig,\s*"\/BackingFile",\s*backingFile/);
  assert.match(source, /CSV export[\s\S]*csvStats.size <= 256 \* 1024 \* 1024[\s\S]*inspectWindowsFileTrace\(trace, canaryPath, positiveControlPath, excludedPath\)/);
});

test("AC-05: native child inspection is ownership-scoped, bounded and metadata-only", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /EnumChildWindows\(root, callback, IntPtr.Zero\)/);
  assert.match(inspection, /seen.Count >= 256 \|\| !seen.Add\(window\)/);
  assert.match(inspection, /processId != ownerProcessId/);
  assert.match(inspection, /finalProcessId != ownerProcessId/);
  assert.match(inspection, /if \(failure != null\) throw new InvalidOperationException\(failure\)/);
  assert.match(inspection, /case "ToolbarWindow32": toolbars\+\+; toolbar = window; break;/);
  assert.doesNotMatch(inspection, /GetWindowText|PostMessage|SetWindow/);
  assert.match(driver, /nativeCounts.slice\(2\).reduce/);
  assert.match(driver, /nativeCounts\[1\] <= nativeCounts\[0\]/);
});

test("AC-05: toolbar MSAA uses bounded read-only same-process client-object queries", async () => {
  const source = await readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8");
  assert.match(source, /AccessibleObjectFromWindow\(toolbar, unchecked\(\(uint\)-4\)/);
  assert.match(source, /count < 0 \|\| count > 64/);
  assert.match(source, /toolbars == 1 \? ReadToolbar/);
  assert.match(source, /finally \{ Marshal.ReleaseComObject\(accessible\); \}/);
  assert.doesNotMatch(source, /accDoDefaultAction|accSelect|set_acc|PostMessage/);
});

test("AC-05: final list count uses only a bounded numeric read before shutdown", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /ReadListCount\(window, 0x1004, UIntPtr.Zero, IntPtr.Zero, 0x22, 2000, out result\)/);
  assert.match(inspection, /name.ToString\(\) != "SysListView32"/);
  assert.match(inspection, /count > Int32.MaxValue/);
  assert.match(inspection, /if \(\$CountOnly\) \{ exit 0 \}/);
  assert.match(driver, /await readCaptureListCount\("after-controls", true\)[\s\S]*command\.send\("start"\)/);
  assert.match(driver, /WDIO finished[\s\S]*await readCaptureListCount\("final"\)[\s\S]*await runProcmon\(\["\/AcceptEula", "\/Terminate"\]/);
  assert.match(driver, /output\.length \+ chunk\.length > 2048[\s\S]*waitWithTimeout\(inspectionExit, 20_000\)/);
});

test("AC-05: capture startup diagnostics classify exact known errors without exposing UI text", async () => {
  const [inspection, driver] = await Promise.all([
    readFile(new URL("../../scripts/inspect-windows-procmon-capture.ps1", import.meta.url), "utf8"),
    readFile(new URL("../../scripts/test-windows-file-access.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(inspection, /\$state.Name -ceq \$errorText/);
  assert.match(inspection, /ClassName -ceq "#32770"/);
  assert.match(inspection, /windowPattern.Current.IsModal/);
  assert.match(inspection, /startupErrors.Count -eq 0\) \{ "none" \}/);
  assert.match(inspection, /PROC_MON_CAPTURE_CONTEXT=class:\$rootClass;modal:\$modal;texts:\$texts;startup-error:\$startupError/);
  assert.match(driver, /contextEvidence.length === 1 && Number\(contextEvidence\[0\]\[3\]\) <= 256/);
  assert.match(driver, /assert.equal\(contextEvidence\[0\]\[4\], "none"/);
  assert.doesNotMatch(inspection, /WriteLine\([^)]*(?:state.Name|ClassName|Exception)/);
});

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
  assert.doesNotMatch(inspection, /switch \(\$state.ControlType\)/);
  assert.match(inspection, /ControlType.Equals\(\[System.Windows.Automation.ControlType\]::ToolBar\)/);
  assert.match(inspection, /elseif \(\$state.ControlType.Equals\(\[System.Windows.Automation.ControlType\]::Button\)/);
  assert.match(inspection, /elseif \(\$state.ControlType.Equals\(\[System.Windows.Automation.ControlType\]::MenuItem\)/);
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
