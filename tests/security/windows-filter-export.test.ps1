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
Add-Type -TypeDefinition $nativeCaptureLiteral.Value
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
$nativeTestForm = [System.Windows.Forms.Form]::new()
try {
  $nativeTestChild = [System.Windows.Forms.TextBox]::new()
  $nativeTestForm.Controls.Add($nativeTestChild)
  $nativeTestHandle = $nativeTestForm.Handle
  $nativeTestChildHandle = $nativeTestChild.Handle
  $nativeCaptureResult = [ProcmonCaptureWindows]::Inspect($nativeTestHandle, [uint32]$PID)
  if ($nativeCaptureResult -notmatch '^children:1;visible:0;toolbars:0;lists:0;statusbars:0;dialogs:0;other:1$') {
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
} finally {
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
