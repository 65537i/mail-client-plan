$ErrorActionPreference = "Stop"

$inspectionSource = Join-Path $PSScriptRoot "../../scripts/inspect-windows-procmon-capture.ps1"
$inspectionTokens = $null
$inspectionErrors = $null
$inspectionAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $inspectionSource, [ref]$inspectionTokens, [ref]$inspectionErrors
)
if ($inspectionErrors.Count -ne 0) {
  throw "Procmon capture inspection script has PowerShell parse errors"
}
$inspectionText = $inspectionAst.Extent.Text
$driverEvidenceFunction = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ProcmonDriverEvidence"
}, $true)
if ($null -eq $driverEvidenceFunction) { throw "Procmon driver formatter is missing" }
. ([scriptblock]::Create($driverEvidenceFunction.Extent.Text))
if ((Get-ProcmonDriverEvidence @()) -cne "inventory:0;candidates:0;name-matches:0;image-matches:0;running:0;started:0;filesystem:0;exit-errors:0") {
  throw "Empty driver inventory must remain an empty observation"
}
$driverFixtures = @(
  [pscustomobject]@{
    Name = "PROCMON24"; PathName = "\SystemRoot\System32\drivers\PROCMON24.SYS"; State = "Running"; Started = $true
    ServiceType = "File System Driver"; ExitCode = [uint32]0
  },
  [pscustomobject]@{
    Name = "PROCALT"; PathName = """C:\Windows\System32\drivers\PROCMON25.SYS"""; State = "Stopped"; Started = $false
    ServiceType = "Kernel Driver"; ExitCode = [uint32]5
  },
  [pscustomobject]@{
    Name = "UNRELATED"; PathName = $null; State = "Running"; Started = $true
    ServiceType = "Kernel Driver"; ExitCode = [uint32]0
  }
)
if ((Get-ProcmonDriverEvidence $driverFixtures) -cne "inventory:3;candidates:2;name-matches:1;image-matches:2;running:1;started:1;filesystem:1;exit-errors:1") {
  throw "SCM driver inventory must identify Procmon candidates by service name or image path"
}
$registryFormatter = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ProcmonRegistryEvidence"
}, $true)
if ($null -eq $registryFormatter) { throw "Procmon registry formatter is missing" }
. ([scriptblock]::Create($registryFormatter.Extent.Text))
$serviceStatusFunction = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ProcmonServiceStatusEvidence"
}, $true)
if ($null -eq $serviceStatusFunction) { throw "Procmon service status formatter is missing" }
. ([scriptblock]::Create($serviceStatusFunction.Extent.Text))
$filterManagerFunction = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ProcmonFilterManagerEvidence"
}, $true)
if ($null -eq $filterManagerFunction) { throw "Procmon Filter Manager formatter is missing" }
. ([scriptblock]::Create($filterManagerFunction.Extent.Text))
if ((Get-ProcmonFilterManagerEvidence @()) -cne "candidates:0;instances:0") {
  throw "Empty Filter Manager inventory must remain an empty observation"
}
$filterVolumeFunction = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ProcmonFilterManagerVolumeEvidence"
}, $true)
if ($null -eq $filterVolumeFunction) { throw "Procmon volume formatter is missing" }
. ([scriptblock]::Create($filterVolumeFunction.Extent.Text))
$filterManagerFixtures = @(
  "Filter Name                     Num Instances    Altitude    Frame",
  "------------------------------  -------------  ------------  -----",
  "WdFilter                        4              328010        0",
  "PROCMON24                       2              385200        0"
)
if ((Get-ProcmonFilterManagerEvidence $filterManagerFixtures) -cne "candidates:1;instances:2") {
  throw "Filter Manager inventory must identify Procmon without exposing filter names"
}
$invalidFilterManagerInputs = @(
  [pscustomobject]@{ Lines = [string[]]@("PROCMON24 invalid") }
  [pscustomobject]@{ Lines = [string[]]@("PROCMON24 1000 385200 0") }
  [pscustomobject]@{ Lines = [string[]](@("PROCMON24 0 385200 0") * 65) }
  [pscustomobject]@{ Lines = [string[]](@("WdFilter") * 257) }
  [pscustomobject]@{ Lines = [string[]]@([string]::new('x', 513)) }
)
foreach ($invalidLines in $invalidFilterManagerInputs) {
  $rejected = $false
  try { Get-ProcmonFilterManagerEvidence $invalidLines.Lines | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Unsafe Filter Manager inventory must be rejected" }
}
$volumeHeader = "Filter Name                     Num Instances    Altitude    Frame    SprtFtrs"
$volumeSeparator = "------------------------------  -------------  ------------  -----    --------"
$targetVolumeFixtures = @(
  $volumeHeader,
  $volumeSeparator,
  "WdFilter                        4              328010        0        0x00",
  "PROCMON24                       2              385200        0        0x00"
)
$targetVolumeEvidence = Get-ProcmonFilterManagerVolumeEvidence $targetVolumeFixtures
if ($targetVolumeEvidence -cne "candidates:1;instances:2" -or
  $script:filterManagerVolumeParseState -cne "valid") {
  throw "Procmon target-volume query must count its exact filter summary"
}
if ((Get-ProcmonFilterManagerVolumeEvidence @(
    "Filter Name Num Instances Altitude Frame",
    "------------------------------ ------------- ------------ -----",
    "PROCMON24 2 385200 0"
  )) -cne "candidates:1;instances:2") {
  throw "A volume summary without supported-features metadata must remain parseable"
}
if ((Get-ProcmonFilterManagerVolumeEvidence @($volumeHeader, $volumeSeparator)) -cne "candidates:0;instances:0") {
  throw "A valid empty target-volume query must remain unattached"
}
$expectedVolumeHeadingEvidence = Get-ProcmonFilterManagerVolumeEvidence @(
  "Instances for C:\",
  $volumeHeader,
  $volumeSeparator,
  "PROCMON24 2 385200 0 0x00"
) "C:"
if ($expectedVolumeHeadingEvidence -cne "candidates:1;instances:2" -or
  $script:filterManagerVolumeParseState -cne "valid") {
  throw "A target-volume summary heading must match the queried volume exactly"
}
$wrongVolumeHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for D:",
    $volumeHeader,
    $volumeSeparator
  ) "C:" | Out-Null
} catch { $wrongVolumeHeadingRejected = $true }
if (-not $wrongVolumeHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-drive-other") {
  throw "A mismatched target-volume heading must fail closed"
}
$drivePathHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for D:\nested"
  ) "C:" | Out-Null
} catch { $drivePathHeadingRejected = $true }
if (-not $drivePathHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-drive-path") {
  throw "A mismatched drive path heading must fail closed"
}
$decoratedDriveHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for D: (metadata)"
  ) "C:" | Out-Null
} catch { $decoratedDriveHeadingRejected = $true }
if (-not $decoratedDriveHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-drive-decorated-parenthesis") {
  throw "A decorated drive heading must fail closed"
}
$decoratedDriveShapeFixtures = @(
  [pscustomobject]@{ Heading = "Instances for D: [metadata]"; State = "volume-heading-drive-decorated-bracket" }
  [pscustomobject]@{ Heading = "Instances for D: 'metadata'"; State = "volume-heading-drive-decorated-quoted" }
  [pscustomobject]@{ Heading = "Instances for D: metadata"; State = "volume-heading-drive-decorated-other" }
)
foreach ($fixture in $decoratedDriveShapeFixtures) {
  $rejected = $false
  try { Get-ProcmonFilterManagerVolumeEvidence @($fixture.Heading) "C:" | Out-Null } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerVolumeParseState -cne $fixture.State) {
    throw "A drive heading decoration must remain rejected and safely classified"
  }
}
$guidVolumeHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for \\?\Volume{malformed}"
  ) "C:" | Out-Null
} catch { $guidVolumeHeadingRejected = $true }
if (-not $guidVolumeHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-guid-prefix") {
  throw "A volume-GUID prefix must fail closed without exposing the identifier"
}
$deviceVolumeHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for \Device\HarddiskVolume12:metadata"
  ) "C:" | Out-Null
} catch { $deviceVolumeHeadingRejected = $true }
if (-not $deviceVolumeHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-device-prefix") {
  throw "An NT-device prefix must fail closed without exposing the device name"
}
$objectManagerHeadingRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    "Instances for \??\Volume{example}"
  ) "C:" | Out-Null
} catch { $objectManagerHeadingRejected = $true }
if (-not $objectManagerHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-object-manager-prefix") {
  throw "An object-manager volume prefix must fail closed without exposing the name"
}
$emptyInstanceOutputRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @() | Out-Null } catch { $emptyInstanceOutputRejected = $true }
if (-not $emptyInstanceOutputRejected) {
  throw "An empty target-volume query output must not be interpreted as unattached"
}
$tooManyProcmonVolumeRows = @($volumeHeader, $volumeSeparator)
for ($index = 0; $index -lt 65; $index++) {
  $tooManyProcmonVolumeRows += "PROCMON24 1 385200 0 0x00"
}
$invalidVolumeInputs = @(
  [pscustomobject]@{ Lines = [string[]]@("unexpected output") }
  [pscustomobject]@{ Lines = [string[]]@("Filter Name Num Instances Altitude Invalid", $volumeSeparator) }
  [pscustomobject]@{ Lines = [string[]]@($volumeHeader, $volumeSeparator, "PROCMON24 invalid") }
  [pscustomobject]@{ Lines = [string[]]@($volumeHeader, $volumeSeparator, "PROCMON24 65 385200 0 0x00") }
  [pscustomobject]@{ Lines = [string[]]@($volumeHeader, $volumeSeparator, "PROCMON24 2 385200 0 invalid") }
  [pscustomobject]@{ Lines = [string[]]@([string]::new('x', 513)) }
  [pscustomobject]@{ Lines = [string[]]$tooManyProcmonVolumeRows }
)
foreach ($invalidLines in $invalidVolumeInputs) {
  $rejected = $false
  try { Get-ProcmonFilterManagerVolumeEvidence $invalidLines.Lines | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Unsafe Procmon target-volume inventory must be rejected" }
}
$unexpectedPreambleRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @("unexpected output") | Out-Null } catch { $unexpectedPreambleRejected = $true }
if (-not $unexpectedPreambleRejected -or
  $script:filterManagerVolumeParseState -cne "unexpected-preamble") {
  throw "Filter Manager parser diagnostics must use a bounded, allowlisted shape code"
}
$volumeHeadingRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @("Instances for volume C:") | Out-Null } catch { $volumeHeadingRejected = $true }
if (-not $volumeHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "volume-heading-other") {
  throw "Filter Manager volume headings must remain untrusted and safely classified"
}
$instancesHeadingRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @("Instances on volume C:") | Out-Null } catch { $instancesHeadingRejected = $true }
if (-not $instancesHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "instances-heading") {
  throw "Filter Manager instance headings must remain untrusted and safely classified"
}
$instanceHeadingRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @("Instance attached to volume C:") | Out-Null } catch { $instanceHeadingRejected = $true }
if (-not $instanceHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "instance-heading") {
  throw "Filter Manager singular instance headings must remain untrusted and safely classified"
}
$filterHeadingRejected = $false
try { Get-ProcmonFilterManagerVolumeEvidence @("Filter instances on volume C:") | Out-Null } catch { $filterHeadingRejected = $true }
if (-not $filterHeadingRejected -or
  $script:filterManagerVolumeParseState -cne "filter-heading") {
  throw "Filter Manager filter headings must remain untrusted and safely classified"
}
Write-Host "PASS AC-05: Filter Manager volume inventory is bounded and counts Procmon instances only"
$registryFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("procmon-registry-test-" + [Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($registryFixtureRoot) | Out-Null
$registryFixturePath = Join-Path $registryFixtureRoot "image.sys"
[IO.File]::WriteAllText($registryFixturePath, "synthetic driver")
$registryFixtureName = "Software\mail-client-plan-test\" + [Guid]::NewGuid().ToString("N")
$registryRootKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryFixtureName)
$missingRegistryKey = $null
$presentRegistryKey = $null
$registryFixtureRootKey = $null
try {
  $presentRegistryKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
    "$registryFixtureName\PROCMON24"
  )
  $presentRegistryKey.SetValue("ImagePath", $registryFixturePath, [Microsoft.Win32.RegistryValueKind]::String)
  $presentRegistryKey.SetValue("Type", [int]2, [Microsoft.Win32.RegistryValueKind]::DWord)
  $presentRegistryKey.SetValue("Start", [int]3, [Microsoft.Win32.RegistryValueKind]::DWord)
  $parametersKey = $presentRegistryKey.CreateSubKey("Parameters")
  $parametersKey.Close()
  $presentRegistryKey.Close()
  $missingRegistryKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
    "$registryFixtureName\ProcMonMissing"
  )
  $missingRegistryKey.Close()
  $registryRootKey.Close()
  $registryFixtureRootKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
    $registryFixtureName, $false
  )
  $registryFixtureEvidence = Get-ProcmonRegistryEvidence $registryFixtureRootKey
  if ($registryFixtureEvidence.Evidence -cne "keys:2;candidates:2;standard-name-candidates:1;other-candidates:1;image-value-entries:1;image-candidates:1;image-values:1;image-paths-present:1;type-values:1;start-values:1;parameters-keys:1" -or
    $registryFixtureEvidence.Names.Count -ne 2) {
    throw "Registry inventory must count candidate image paths without exposing them"
  }
  $missingServiceName = "ProcMonSynthetic" + [Guid]::NewGuid().ToString("N")
  if ((Get-ProcmonServiceStatusEvidence @($missingServiceName)) -cne "candidates:1;found:0;not-found:1;running:0;stopped:0;other-states:0") {
    throw "SCM query must classify only the documented missing-service result"
  }
  for ($index = 0; $index -lt 65; $index++) {
    $excessKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey(
      "$registryFixtureName\ProcMonCandidate$index"
    )
    $excessKey.Close()
  }
  $rejected = $false
  try { Get-ProcmonRegistryEvidence $registryFixtureRootKey | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Oversized Procmon registry candidate inventory must be rejected" }
  Write-Host "PASS AC-05: registry inventory counts present/missing image paths and enforces its limit"
} finally {
  if ($null -ne $registryFixtureRootKey) { $registryFixtureRootKey.Dispose() }
  if ($null -ne $presentRegistryKey) { $presentRegistryKey.Dispose() }
  if ($null -ne $missingRegistryKey) { $missingRegistryKey.Dispose() }
  $registryRootKey.Dispose()
  [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryFixtureName, $false)
  Remove-Item -LiteralPath $registryFixtureRoot -Recurse -Force
}
foreach ($invalid in @(
  (@($driverFixtures[0]) * 1025),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = 1; State = "Running"; Started = $true; ServiceType = "Kernel Driver"; ExitCode = [uint32]0 }),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = [string]::new('x', 2049); State = "Running"; Started = $true; ServiceType = "Kernel Driver"; ExitCode = [uint32]0 }),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = "\SystemRoot\System32\drivers\PROCMON24.SYS"; State = "secret"; Started = $true; ServiceType = "Kernel Driver"; ExitCode = [uint32]0 }),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = "\SystemRoot\System32\drivers\PROCMON24.SYS"; State = "Running"; Started = "false"; ServiceType = "Kernel Driver"; ExitCode = [uint32]0 }),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = "\SystemRoot\System32\drivers\PROCMON24.SYS"; State = "Running"; Started = $true; ServiceType = "secret"; ExitCode = [uint32]0 }),
  @([pscustomobject]@{ Name = "PROCMON24"; PathName = "\SystemRoot\System32\drivers\PROCMON24.SYS"; State = "Running"; Started = $true; ServiceType = "Kernel Driver"; ExitCode = "secret" })
)) {
  $rejected = $false
  try { Get-ProcmonDriverEvidence $invalid | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Unsafe driver inventory must be rejected" }
}
Write-Host "PASS AC-05: driver inventory counts empty, running and stopped services and rejects unsafe shapes"
$windowSummary = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
    $node.Extent.Text -match '^\[Console\]::Out.WriteLine\(\s*"PROC_MON_CAPTURE_WINDOW='
}, $true)
$summaryParent = $windowSummary
while ($null -ne $summaryParent) {
  if ($summaryParent -is [System.Management.Automation.Language.LoopStatementAst]) {
    throw "Capture window summary must be emitted once after the UI scan"
  }
  $summaryParent = $summaryParent.Parent
}
if (
  $null -eq $windowSummary -or
  $inspectionText -notmatch 'GetProcessById\(\$OwnerProcessId\)' -or
  $inspectionText -notmatch '\$state.ProcessId -ne \$OwnerProcessId' -or
  $inspectionText -notmatch '\$visited \+ \$pending.Count -ge 256' -or
  $inspectionText -notmatch 'TogglePattern\]::Pattern' -or
  $inspectionText -notmatch 'SelectionItemPattern\]::Pattern' -or
  $inspectionText -notmatch 'windowPattern.Current.WindowVisualState' -or
  $inspectionText -notmatch 'PROC_MON_CAPTURE_WINDOW=visual:\$visual' -or
  $inspectionText -match 'switch \(\$state.ControlType\)' -or
  $inspectionText -notmatch 'ControlType.Equals\(\[System.Windows.Automation.ControlType\]::ToolBar\)' -or
  $inspectionText -notmatch '\$state.Name -ceq \$errorText' -or
  $inspectionText -notmatch 'PROC_MON_CAPTURE_CONTEXT=class:\$rootClass' -or
  $inspectionText -match 'Invoke\(|Toggle\(|Select\(|SendKeys|SetFocus|SetForegroundWindow|SetWindowVisualState|ShowWindow'
) {
  throw "Capture inspection must remain bounded, same-process and read-only"
}
Write-Host "PASS AC-05: capture inspection parses and remains bounded and read-only"
$nativeCaptureLiteral = $inspectionAst.Find({
  param($node)
  $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -match 'public static class ProcmonCaptureWindows'
}, $true)
if ($null -eq $nativeCaptureLiteral) {
  throw "Native capture inspection helper is missing"
}
Add-Type -AssemblyName Accessibility
Add-Type -TypeDefinition $nativeCaptureLiteral.Value `
  -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location)
$invalidRootRejected = $false
try {
  [ProcmonCaptureWindows]::Inspect([IntPtr]::Zero, [uint32]$PID) | Out-Null
} catch [System.Management.Automation.MethodInvocationException] {
  if ($_.Exception.InnerException -isnot [InvalidOperationException]) { throw }
  $invalidRootRejected = $true
}
if (-not $invalidRootRejected) {
  throw "Native capture inspection must reject an invalid root"
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyntheticListCount
{
    [DllImport("user32.dll", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern IntPtr Create(
        uint extendedStyle, string className, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", ExactSpelling = true)]
    public static extern IntPtr SetCount(IntPtr window, uint message, IntPtr count, IntPtr flags);
}
'@
$nativeTestForm = [System.Windows.Forms.Form]::new()
$testListHandle = [IntPtr]::Zero
try {
  $nativeTestChild = [System.Windows.Forms.TextBox]::new()
  $nativeTestForm.Controls.Add($nativeTestChild)
  $nativeTestHandle = $nativeTestForm.Handle
  $nativeTestChildHandle = $nativeTestChild.Handle
  $nativeCaptureResult = [ProcmonCaptureWindows]::Inspect($nativeTestHandle, [uint32]$PID)
  if ($nativeCaptureResult -cne "children:1;visible:0;toolbars:0;lists:0;statusbars:0;dialogs:0;other:1`nPROC_MON_CAPTURE_MSAA=capture;object:unavailable;items:0;matches:0;checked:unavailable;enabled:unavailable`nPROC_MON_CAPTURE_MSAA=filesystem;object:unavailable;items:0;matches:0;checked:unavailable;enabled:unavailable`nPROC_MON_CAPTURE_LIST=items:unavailable") {
    throw "Native capture inspection did not classify the hidden synthetic child"
  }
  $foreignRootRejected = $false
  try {
    [ProcmonCaptureWindows]::Inspect($nativeTestHandle, [uint32]0) | Out-Null
  } catch [System.Management.Automation.MethodInvocationException] {
    if ($_.Exception.InnerException -isnot [InvalidOperationException]) { throw }
    $foreignRootRejected = $true
  }
  if (-not $foreignRootRejected) {
    throw "Native capture inspection must reject a foreign root"
  }
  $listInitializer = [System.Windows.Forms.ListView]::new()
  $listInitializerHandle = $listInitializer.Handle
  $listInitializer.Dispose()
  $testListHandle = [SyntheticListCount]::Create(
    0, "SysListView32", "", 0x40001000, 0, 0, 100, 100,
    $nativeTestHandle, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero
  )
  if ($testListHandle -eq [IntPtr]::Zero) { throw "Synthetic native list creation failed" }
  [SyntheticListCount]::SetCount($testListHandle, 0x102f, [IntPtr]2, [IntPtr]::Zero) | Out-Null
  if ([ProcmonCaptureWindows]::CountListItems($testListHandle, [uint32]$PID) -cne "2") {
    throw "Native list count did not observe exactly two synthetic items"
  }
  [SyntheticListCount]::SetCount($testListHandle, 0x102f, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  if ([ProcmonCaptureWindows]::CountListItems($testListHandle, [uint32]$PID) -cne "0") {
    throw "Native list count did not observe zero synthetic items"
  }
} finally {
  if ($testListHandle -ne [IntPtr]::Zero -and -not [SyntheticListCount]::DestroyWindow($testListHandle)) {
    throw "Synthetic native list cleanup failed"
  }
  $nativeTestForm.Dispose()
}
Write-Host "PASS AC-05: native child inspection compiles, classifies a hidden child and rejects invalid ownership"

$source = Join-Path $PSScriptRoot "../../scripts/configure-windows-procmon-filter.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $source, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "Procmon configuration script has PowerShell parse errors"
}
$sourceText = [IO.File]::ReadAllText($source)
if (
  $sourceText -notmatch 'GetProcessById\(\$CaptureProcessId\)' -or
  $sourceText -notmatch '\$process.Path -cne \[IO.Path\]::GetFullPath\(\$ProcmonPath\)' -or
  $sourceText -notmatch 'if \(-not \$PSBoundParameters.ContainsKey\("CaptureProcessId"\)\) \{\s*Set-Stage "wait-for-input-idle"' -or
  $sourceText -notmatch 'if \(-not \$PSBoundParameters.ContainsKey\("CaptureProcessId"\) -and -not \$process.HasExited\)' -or
  $sourceText -notmatch 'PROC_MON_FILTER_LIVE_VERIFIED=rules:exact-two;drop:on'
) {
  throw "Live filter verification must skip setup and preserve the verified capture process"
}
if ($sourceText -notmatch '(?s)Set-Stage "wait-export-config-dialog"\s*try \{\s*\$saveControls = Wait-ConfigSaveDialog \$process \$main\s*\} catch \{\s*Write-ConfigSaveResultObservation "export-timeout" \$process \$main\s*throw\s*\}') {
  throw "Export dialog failure must retain the original failure after a read-only observation"
}
$saveObservationFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ConfigSaveResultObservation"
}, $true)
if ($saveObservationFunction.Extent.Text -notmatch 'PROC_MON_FILTER_SAVE_RESULT_FAILED=phase:\$Phase') {
  throw "Failed save observation must not report successful zero counts"
}
$reloadedStateFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-ReloadedNativeDropCheckState"
}, $true)
$accessibleSnapshotFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-AccessibleDropMenuSnapshot"
}, $true)
$eventMenuPatternFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ReloadedEventMenuPatternSnapshot"
}, $true)
if (
  $sourceText -notmatch 'AccessibleMenuObjectId\s*=\s*-3' -or
  $sourceText -notmatch 'AccessibleClientObjectId\s*=\s*-4' -or
  $sourceText -notmatch '(?s)var objectId = useWindowMenuObject\s*\?.*AccessibleMenuObjectId.*AccessibleClientObjectId' -or
  $null -eq $reloadedStateFunction -or
  $reloadedStateFunction.Extent.Text -notmatch '(?s)Get-AccessibleDropMenuSnapshot\s+`?\s*\$MainWindowHandle\s+\$ProcessId\s+\$true\s+"after-reload"' -or
  $null -eq $accessibleSnapshotFunction -or
  $accessibleSnapshotFunction.Extent.Text -notmatch '(?s)ReadAccessibleDropMenuState\(\s*\$MenuWindowHandle,\s*\$ProcessId,\s*\$UseWindowMenuObject[\s\S]*Set-Stage "read-msaa-process-state"[\s\S]*\$snapshot\.ProcessKnown[\s\S]*Set-Stage "read-msaa-object-state"[\s\S]*\$snapshot\.AccessibleAvailable[\s\S]*Set-Stage "read-msaa-menu-counts"[\s\S]*\$snapshot\.ItemCount[\s\S]*\$snapshot\.MatchCount[\s\S]*Set-Stage "read-msaa-menu-result"[\s\S]*\$snapshot\.ReadFailure[\s\S]*\$snapshot\.CheckState[\s\S]*\$snapshot\.IsEnabled[\s\S]*Set-Stage "report-msaa-menu-state"[\s\S]*PROC_MON_FILTER_MSAA_MENU_STATE[\s\S]*Set-Stage "report-msaa-menu-enabled"[\s\S]*PROC_MON_FILTER_MSAA_MENU_ENABLED' -or
  $null -eq $eventMenuPatternFunction -or
  $eventMenuPatternFunction.Extent.Text -notmatch '(?s)PropertyCondition\]::new\([\s\S]*ControlTypeProperty[\s\S]*ControlType\]::MenuItem' -or
  $eventMenuPatternFunction.Extent.Text -notmatch '(?s)InvokePattern\]::Pattern[\s\S]*ExpandCollapsePattern\]::Pattern[\s\S]*SelectionItemPattern\]::Pattern' -or
  $eventMenuPatternFunction.Extent.Text -match 'LegacyIAccessiblePattern' -or
  $eventMenuPatternFunction.Extent.Text -notmatch '(?s)Set-Stage "probe-reloaded-event-main-window"[\s\S]*AutomationElement\]::FromHandle[\s\S]*Set-Stage "probe-reloaded-event-window-process"[\s\S]*Current\.ProcessId[\s\S]*Set-Stage "probe-reloaded-event-menu-items"[\s\S]*FindAll\([\s\S]*Set-Stage "probe-reloaded-event-menu-item-names"[\s\S]*foreach \(\$item in \$menuItems\)[\s\S]*Set-Stage "probe-reloaded-event-item-state"[\s\S]*\$eventItem\.Current[\s\S]*Set-Stage "probe-reloaded-event-invoke-pattern"[\s\S]*InvokePattern\]::Pattern[\s\S]*Set-Stage "probe-reloaded-event-expand-collapse-pattern"[\s\S]*ExpandCollapsePattern\]::Pattern[\s\S]*Set-Stage "probe-reloaded-event-selection-item-pattern"[\s\S]*SelectionItemPattern\]::Pattern' -or
  $reloadedStateFunction.Extent.Text -notmatch '(?s)Write-NativeDropMenuSnapshot[\s\S]*Write-ReloadedEventMenuPatternSnapshot\s+\$MainWindowHandle\s+\$ProcessId[\s\S]*Set-Stage "read-reloaded-msaa-menu-state"[\s\S]*Get-AccessibleDropMenuSnapshot[\s\S]*Set-Stage "consume-reloaded-msaa-menu-state"[\s\S]*\$accessibleSnapshot\.CheckState[\s\S]*Set-Stage "verify-reloaded-drop-check-state"'
) {
  throw "Reloaded menu state must probe the Event item's read-only UI Automation patterns"
}
Write-Host "PASS AC-05: reloaded menu state probes bounded Event menu patterns without activation"
$reloadPopupFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Read-ReloadedFilterPopupState"
}, $true)
if (
  $null -eq $reloadPopupFunction -or
  $reloadPopupFunction.Extent.Text -notmatch '\$items.Count -ne 1' -or
  $reloadPopupFunction.Extent.Text -notmatch '\$parent.Current.ControlType -ne \[System.Windows.Automation.ControlType\]::ToolBar' -or
  $reloadPopupFunction.Extent.Text -notmatch 'GetForegroundWindow\(\) -ne \$MainWindowHandle' -or
  $reloadPopupFunction.Extent.Text -notmatch '(?s)\$filter.GetCurrentPattern\(\[System.Windows.Automation.InvokePattern\]::Pattern\)[\s\S]*\$pattern.Invoke\(\)[\s\S]*Wait-ProcessMenu[\s\S]*\$popupHandle -eq \$MainWindowHandle[\s\S]*\$drops.Count -ne 1[\s\S]*\$dropState.ProcessId -ne \$ProcessId[\s\S]*Get-NativeDropMenuSnapshot[\s\S]*Get-AccessibleDropMenuSnapshot \$popupHandle \$ProcessId \$false "after-reload"[\s\S]*Get-VerifiedDropMenuCheckState' -or
  ([regex]::Matches($reloadPopupFunction.Extent.Text, '\.Invoke\(')).Count -ne 1 -or
  $reloadPopupFunction.Extent.Text -match 'Toggle\(|SendKeys|SelectionItemPattern' -or
  $reloadedStateFunction.Extent.Text -notmatch '(?s)if \(\$checkState -eq "unavailable"\)[\s\S]*Read-ReloadedFilterPopupState \$MainWindowHandle \$ProcessId'
) {
  throw "Reloaded popup read must open only one verified Filter toolbar item and never invoke Drop"
}
Write-Host "PASS AC-05: reloaded popup read opens only the verified Filter toolbar menu"
$closeReloadedDialogFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Close-ReloadedFilterDialog"
}, $true)
if (
  $null -eq $closeReloadedDialogFunction -or
  $closeReloadedDialogFunction.Extent.Text -notmatch '\$dialogHandle -eq \$mainHandle' -or
  $closeReloadedDialogFunction.Extent.Text -notmatch '\$dialogState\.ProcessId -ne \$OwnerProcessId' -or
  $closeReloadedDialogFunction.Extent.Text -notmatch '\$mainState\.ProcessId -ne \$OwnerProcessId' -or
  $closeReloadedDialogFunction.Extent.Text -notmatch '(?s)GetWindowProcessId\(\$dialogHandle\)[\s\S]*GetWindowProcessId\(\$mainHandle\)[\s\S]*IsWindowVisible\(\$dialogHandle\)[\s\S]*WindowPattern\]::Pattern[\s\S]*\$windowPattern\.Close\(\)[\s\S]*Set-Stage "wait-reloaded-filter-dialog-closed"[\s\S]*IsWindowVisible\(\$dialogHandle\)[\s\S]*Set-Stage "restore-reloaded-main-window"[\s\S]*SetForegroundWindow\(\$mainHandle\)[\s\S]*\$currentMainState\.IsEnabled[\s\S]*GetForegroundWindow\(\)[\s\S]*IsWindowVisible\(\$dialogHandle\)' -or
  $closeReloadedDialogFunction.Extent.Text -match 'SendKeys|\.Invoke\(' -or
  $sourceText -notmatch '(?s)Set-Stage "verify-reloaded-filter-rules"\s*Get-LoadedFilterRuleEvidence[^\r\n]*\r?\n\s*Close-ReloadedFilterDialog \$reloadFilterDialog \$main \$process.Id[\s\S]*Set-Stage "read-reloaded-drop-state"'
) {
  throw "Reloaded rules must be verified before closing only the same-process filter dialog and restoring the main window"
}
Write-Host "PASS AC-05: reloaded dialog closure is scoped and verified before the Drop state read"
$ruleRowsFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Get-LoadedFilterRuleRows"
}, $true)
$reloadRowCalls = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq "Get-LoadedFilterRuleRows" -and
    $node.Extent.Text -match '-Reloaded\b'
}, $true)
if (
  $null -eq $ruleRowsFunction -or
  $ruleRowsFunction.Extent.Text -notmatch '\[switch\]\$Reloaded' -or
  $ruleRowsFunction.Extent.Text -notmatch '\$observation = if \(\$Reloaded\) \{ "RELOADED" \} else \{ "INITIAL" \}' -or
  $ruleRowsFunction.Extent.Text -notmatch 'PROC_MON_FILTER_\$\{observation\}_UI=' -or
  $ruleRowsFunction.Extent.Text -notmatch 'PROC_MON_FILTER_\$\{observation\}_ROW_SHAPE=' -or
  $reloadRowCalls.Count -ne 1 -or
  $reloadRowCalls[0].Extent.Text -cne 'Get-LoadedFilterRuleRows $reloadFilterDialog $process.Id -Reloaded'
) {
  throw "Only the reloaded dialog may emit reloaded rule UI evidence"
}
Write-Host "PASS AC-05: initial rule UI cannot masquerade as reloaded evidence"
$functions = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @(
      "Get-ConfigHeaderClass",
      "Write-ConfigOutputObservation",
      "Wait-FilterConfigFile",
      "Get-ConfigFilterPathEvidence",
      "Get-LoadedFilterRuleEvidence",
      "Get-UniqueConfigSaveDialogMatch",
      "Wait-ProcessMenu",
      "Wait-KeyboardFocus",
      "ConvertTo-SendKeysLiteral"
    )
}, $true)
if ($functions.Count -ne 9) {
  throw "Expected the configuration file observation functions"
}
foreach ($function in $functions) {
  . ([scriptblock]::Create($function.Extent.Text))
}

$noDialog = Get-UniqueConfigSaveDialogMatch ([System.Collections.ArrayList]::new())
$oneDialogCandidate = [System.Collections.ArrayList]::new()
$oneDialogCandidate.Add(@{ Dialog = "dialog"; FileName = "file-name"; Save = "save" }) | Out-Null
$uniqueDialog = Get-UniqueConfigSaveDialogMatch $oneDialogCandidate
$multipleDialogCandidates = [System.Collections.ArrayList]::new()
$multipleDialogCandidates.Add("first") | Out-Null
$multipleDialogCandidates.Add("second") | Out-Null
$multipleDialogsRejected = $false
try {
  Get-UniqueConfigSaveDialogMatch $multipleDialogCandidates | Out-Null
} catch {
  if ($_.Exception.Message -ne
    "Process Monitor exposed multiple configuration save dialogs") {
    throw
  }
  $multipleDialogsRejected = $true
}
if (
  $null -ne $noDialog -or
  $null -eq $uniqueDialog -or
  $uniqueDialog.Dialog -cne "dialog" -or
  $uniqueDialog.FileName -cne "file-name" -or
  $uniqueDialog.Save -cne "save" -or
  -not $multipleDialogsRejected
) {
  throw "Configuration save dialog uniqueness gate did not handle zero, one, and multiple candidates"
}
Write-Host "PASS AC-05: save dialog matching accepts exactly one candidate"

$previousOutput = [Console]::Out
$capturedOutput = [IO.StringWriter]::new()
try {
  [Console]::SetOut($capturedOutput)
  $loadedRules = Get-LoadedFilterRuleEvidence @(
    "Path is C:\audit\canary.png Include",
    "Path is C:\audit\control.png Include"
  ) "C:\audit\canary.png" "C:\audit\control.png"
} finally {
  [Console]::SetOut($previousOutput)
}
if (
  $loadedRules.Rows -ne 2 -or
  $loadedRules.ExactRows -ne 2 -or
  $capturedOutput.ToString().Trim() -cne
  "PROC_MON_FILTER_RELOADED_RULES=rows:2;canary:1;control:1;path:2;is:2;include:2;unclassified:0" -or
  $capturedOutput.ToString().Contains("C:\audit")
) {
  throw "Exact reloaded filter rules were not verified with bounded evidence"
}
Write-Host "PASS AC-05: reloaded exact Path/is/Include rules are confirmed without exposing paths"

$capturedOutput = [IO.StringWriter]::new()
try {
  [Console]::SetOut($capturedOutput)
  $loadedRuleItems = Get-LoadedFilterRuleEvidence @(
    [pscustomobject]@{ Text = "Path is C:\audit\canary.png Include" }
    [pscustomobject]@{ Text = "Path is C:\audit\control.png Include" }
  ) "C:\audit\canary.png" "C:\audit\control.png"
} finally {
  [Console]::SetOut($previousOutput)
}
if ($loadedRuleItems.ExactRows -ne 2 -or
  $capturedOutput.ToString().Contains("C:\audit")) {
  throw "UI Automation rule items did not preserve exact-rule verification"
}
Write-Host "PASS AC-05: UI Automation row objects use the exact-rule verifier safely"

foreach ($invalidRows in @(
    ,@("Path is C:\audit\canary.png Exclude", "Path is C:\audit\control.png Include")
    ,@("Path is C:\audit\canary.png Include", "Path is C:\audit\control.png Include", "Operation is ReadFile Include")
    ,@("Path contains C:\audit\canary.png Include", "Path is C:\audit\control.png Include")
    ,@("Path is not C:\audit\canary.png Include", "Path is C:\audit\control.png Include")
  )) {
  $capturedOutput = [IO.StringWriter]::new()
  $rejectedRules = $false
  try {
    [Console]::SetOut($capturedOutput)
    try {
      Get-LoadedFilterRuleEvidence $invalidRows "C:\audit\canary.png" "C:\audit\control.png" | Out-Null
    } catch {
      if ($_.Exception.Message -ne
        "Process Monitor did not reload exactly the two required Path Include rules") {
        throw
      }
      $rejectedRules = $true
    }
  } finally {
    [Console]::SetOut($previousOutput)
  }
  if (-not $rejectedRules -or $capturedOutput.ToString().Contains("C:\audit")) {
    throw "Invalid reloaded filter rule state was not rejected without exposing paths"
  }
}
Write-Host "PASS AC-05: extra, excluded, and non-exact reloaded rules fail closed"

$focusState = [pscustomobject]@{
  FocusSequence = [System.Collections.Generic.Queue[bool]]::new()
}
$focusState.FocusSequence.Enqueue($false)
$focusState.FocusSequence.Enqueue($false)
$focusState.FocusSequence.Enqueue($true)
$focusState.FocusSequence.Enqueue($true)
$focusState | Add-Member -MemberType ScriptProperty -Name HasKeyboardFocus -Value {
  if ($this.FocusSequence.Count -gt 0) {
    return $this.FocusSequence.Dequeue()
  }
  return $false
}
$saveControl = [pscustomobject]@{ Current = $focusState }
$confirmedFocus = Wait-KeyboardFocus $saveControl 500
if ($null -eq $confirmedFocus -or -not $confirmedFocus.HasKeyboardFocus) {
  throw "Transient Save button focus was not observed before the deadline"
}

$unfocusedControl = [pscustomobject]@{
  Current = [pscustomobject]@{ HasKeyboardFocus = $false }
}
$unconfirmedFocus = Wait-KeyboardFocus $unfocusedControl 100
if ($null -ne $unconfirmedFocus) {
  throw "Save button without keyboard focus passed the focus gate"
}
if ((ConvertTo-SendKeysLiteral "C:\audit\filter +1%~(^).pmc{}") -cne
  "C:\audit\filter {+}1{%}{~}{(}{^}{)}.pmc{{}{}}") {
  throw "Filename keyboard input did not escape SendKeys metacharacters"
}
Write-Host "PASS AC-05: transient Save focus is verified"

function Assert-Timeout([string]$Path) {
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $rejected = $false
  try {
    Wait-FilterConfigFile $Path 250
  } catch {
    if ($_.Exception.Message -ne
      "Process Monitor did not save the audit filter configuration before the deadline") {
      throw
    }
    $rejected = $true
  }
  if (-not $rejected -or $timer.ElapsedMilliseconds -lt 250 -or
    $timer.ElapsedMilliseconds -gt 5000) {
    throw "Missing or undersized configuration did not fail within the expected deadline"
  }
}

$directory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($directory) | Out-Null
$path = Join-Path $directory "synthetic.pmc"
$inventoryDirectory = Join-Path $directory "inventory"
$evidencePath = Join-Path $directory "filter-evidence.pmc"
$writer = $null
try {
  foreach ($encoding in @(
      [System.Text.Encoding]::UTF8,
      [System.Text.Encoding]::Unicode,
      [System.Text.Encoding]::BigEndianUnicode
    )) {
    $fixture = "opaque configuration C:\audit\canary.png C:\audit\control.png"
    [IO.File]::WriteAllBytes($evidencePath, $encoding.GetBytes($fixture))
    if ((Get-ConfigHeaderClass $evidencePath) -ne "other") {
      throw "Opaque configuration fixture unexpectedly looked like XML or an executable"
    }
    $previousOutput = [Console]::Out
    $capturedOutput = [IO.StringWriter]::new()
    try {
      [Console]::SetOut($capturedOutput)
      $evidence = Get-ConfigFilterPathEvidence $evidencePath "C:\audit\canary.png" "C:\audit\control.png"
    } finally {
      [Console]::SetOut($previousOutput)
    }
    if (
      $evidence.CanaryMatches -ne 1 -or
      $evidence.ControlMatches -ne 1 -or
      $capturedOutput.ToString().Trim() -cne
      "PROC_MON_FILTER_CONFIG_PATHS=canary:1;control:1" -or
      $capturedOutput.ToString().Contains("C:\audit")
    ) {
      throw "Exported filter path evidence was not bounded and sanitized"
    }
  }
  Write-Host "PASS AC-05: opaque exported config evidence supports UTF-8 and UTF-16 paths"

  [IO.File]::WriteAllText(
    $evidencePath,
    '<?xml version="1.0"?><config><filter><path>C:\audit\canary.png</path></filter></config>'
  )
  $previousOutput = [Console]::Out
  $capturedOutput = [IO.StringWriter]::new()
  $missingControlRejected = $false
  try {
    [Console]::SetOut($capturedOutput)
    try {
      Get-ConfigFilterPathEvidence $evidencePath "C:\audit\canary.png" "C:\audit\control.png" | Out-Null
    } catch {
      if ($_.Exception.Message -ne
        "Process Monitor configuration did not retain both audit filter paths") {
        throw
      }
      $missingControlRejected = $true
    }
  } finally {
    [Console]::SetOut($previousOutput)
  }
  if (
    -not $missingControlRejected -or
    $capturedOutput.ToString().Trim() -cne
    "PROC_MON_FILTER_CONFIG_PATHS=canary:1;control:0" -or
    $capturedOutput.ToString().Contains("C:\audit")
  ) {
    throw "Missing exported filter path was not rejected with safe evidence"
  }
  Write-Host "PASS AC-05: missing exported filter paths fail closed"

  [IO.File]::WriteAllBytes($evidencePath, [byte[]]::new(1048577))
  $oversizedRejected = $false
  try {
    Get-ConfigFilterPathEvidence $evidencePath "C:\audit\canary.png" "C:\audit\control.png" | Out-Null
  } catch {
    if ($_.Exception.Message -ne
      "Process Monitor configuration file is not a bounded file") {
      throw
    }
    $oversizedRejected = $true
  }
  if (-not $oversizedRejected) {
    throw "Oversized exported filter configuration was not rejected"
  }
  Write-Host "PASS AC-05: opaque exported configuration reads remain bounded"

  Assert-Timeout $path
  [IO.File]::WriteAllBytes($path, [byte[]]::new(99))
  Assert-Timeout $path
  [IO.File]::WriteAllBytes($path, [byte[]]::new(100))
  Wait-FilterConfigFile $path 250
  Write-Host "PASS AC-05: absent and 99-byte files time out; 100-byte file is accepted"

  [IO.File]::Delete($path)
  [IO.File]::Delete($evidencePath)
  $writer = [PowerShell]::Create()
  $null = $writer.AddScript({
    param($Path)
    Start-Sleep -Milliseconds 200
    [IO.File]::WriteAllBytes($Path, [byte[]]::new(99))
    Start-Sleep -Milliseconds 200
    [IO.File]::WriteAllBytes($Path, [byte[]]::new(100))
  }).AddArgument($path)
  $pendingWrite = $writer.BeginInvoke()
  Wait-FilterConfigFile $path 5000
  $observedLength = (Get-Item -LiteralPath $path).Length
  $writer.EndInvoke($pendingWrite) | Out-Null
  if ($writer.HadErrors -or $observedLength -ne 100) {
    throw "Delayed configuration writer failed"
  }
  Write-Host "PASS AC-05: delayed file creation and growth are awaited"

  $rejectedDirectory = $false
  try {
    Wait-FilterConfigFile $directory 250
  } catch {
    if ($_.Exception.Message -ne "Process Monitor configuration path is not a file") {
      throw
    }
    $rejectedDirectory = $true
  }
  if (-not $rejectedDirectory) { throw "Configuration directory was accepted as a file" }
  Write-Host "PASS AC-05: directory is rejected"

  [IO.File]::Delete($path)
  [IO.Directory]::CreateDirectory($inventoryDirectory) | Out-Null
  $headers = @{
    "empty.pmc" = [byte[]]::new(0)
    "short.pmc" = [byte[]](1, 2)
    "mz.pmc" = [byte[]](0x4d, 0x5a, 1, 2)
    "xml.pmc" = [Text.Encoding]::ASCII.GetBytes("<?xml ver")
    "other.pmc" = [byte[]](1, 2, 3, 4)
  }
  foreach ($entry in $headers.GetEnumerator()) {
    [IO.File]::WriteAllBytes((Join-Path $inventoryDirectory $entry.Key), $entry.Value)
  }
  $safePath = Join-Path $inventoryDirectory "audit-config.pmc"
  $targetBytes = [byte[]]::new(100)
  [Array]::Copy([Text.Encoding]::ASCII.GetBytes("<?xml ver"), $targetBytes, 8)
  [IO.File]::WriteAllBytes($safePath, $targetBytes)
  [IO.File]::WriteAllText((Join-Path $inventoryDirectory "control.txt"), "synthetic")

  $previousOutput = [Console]::Out
  $capturedOutput = [IO.StringWriter]::new()
  try {
    [Console]::SetOut($capturedOutput)
    Write-ConfigOutputObservation "after-wait" $safePath
  } finally {
    [Console]::SetOut($previousOutput)
  }
  $observation = $capturedOutput.ToString().Trim()
  if ($observation -notmatch
    "^PROC_MON_FILTER_CONFIG_OUTPUT=phase:after-wait;target:ready;target-header:xml;pmc-count:6;headers:empty:1;short:1;mz:1;xml:2;other:1;other-count:1;truncated:false$" -or
    $observation.Contains($directory) -or $observation.Contains("audit-config.pmc")) {
    throw "Configuration output inventory was not bounded or sanitized"
  }
  Write-Host "PASS AC-05: output inventory exposes only bounded header classes and counts"
} finally {
  if ($null -ne $writer) {
    $writer.Stop()
    $writer.Dispose()
  }
  [IO.File]::Delete($path)
  if (Test-Path -LiteralPath $inventoryDirectory) {
    foreach ($name in @(
        "empty.pmc", "short.pmc", "mz.pmc", "xml.pmc",
        "other.pmc", "audit-config.pmc", "control.txt"
      )) {
      [IO.File]::Delete((Join-Path $inventoryDirectory $name))
    }
    [IO.Directory]::Delete($inventoryDirectory)
  }
  [IO.Directory]::Delete($directory)
}
