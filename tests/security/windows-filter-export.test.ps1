$ErrorActionPreference = "Stop"

$source = Join-Path $PSScriptRoot "../../scripts/configure-windows-procmon-filter.ps1"
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $source, [ref]$tokens, [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "Procmon configuration script has PowerShell parse errors"
}
$functions = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @(
      "Get-ConfigHeaderClass",
      "Write-ConfigOutputObservation",
      "Wait-FilterConfigFile",
      "Get-ConfigFilterPathEvidence",
      "Get-LoadedFilterRuleEvidence",
      "Wait-KeyboardFocus",
      "ConvertTo-SendKeysLiteral",
      "ConvertTo-ProcmonMenuAccessKey"
    )
}, $true)
if ($functions.Count -ne 8) {
  throw "Expected the configuration file observation functions"
}
foreach ($function in $functions) {
  . ([scriptblock]::Create($function.Extent.Text))
}

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

$focusState = [pscustomobject]@{}
$focusState | Add-Member -MemberType ScriptProperty -Name HasKeyboardFocus -Value {
  $this.ReadCount++
  return $this.ReadCount -ge 3
}
$focusState | Add-Member -MemberType NoteProperty -Name ReadCount -Value 0
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
if ((ConvertTo-ProcmonMenuAccessKey "Alt+F") -cne "%f" -or
  (ConvertTo-ProcmonMenuAccessKey "Alt+f") -cne "%f") {
  throw "Safe single-letter menu access key was not converted"
}
foreach ($unsupportedAccessKey in @("", "F", "Alt+", "Alt+F%{ENTER}", "Alt+é", "C:\private", $null)) {
  if ($null -ne (ConvertTo-ProcmonMenuAccessKey $unsupportedAccessKey)) {
    throw "Unsupported menu access key passed the safe-key gate"
  }
}
Write-Host "PASS AC-05: transient Save focus and bounded menu access keys are verified"

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
