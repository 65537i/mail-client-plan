param(
  [Parameter(Mandatory = $true)][string]$ProcmonPath,
  [Parameter(Mandatory = $true)][string]$CanaryPath,
  [Parameter(Mandatory = $true)][string]$ControlPath,
  [Parameter(Mandatory = $true)][string]$ConfigPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ProcmonWindowActivation {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr windowHandle);
}
"@

$process = Start-Process -FilePath $ProcmonPath -ArgumentList "/AcceptEula" -PassThru

function Wait-Element([System.Windows.Automation.AutomationElement]$Root, [System.Windows.Automation.Condition]$Condition, [int]$TimeoutSeconds = 10) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    if ($null -ne $element) { return $element }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for a Process Monitor UI control"
}

function Wait-TopLevelWindow([string]$NamePattern, [int]$TimeoutSeconds = 10) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  do {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    foreach ($window in $windows) {
      if ($window.Current.Name -match $NamePattern) { return $window }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for Process Monitor window $NamePattern"
}

function Wait-MainWindow([System.Diagnostics.Process]$Process, [int]$TimeoutSeconds = 15) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  do {
    $Process.Refresh()
    if ($Process.HasExited) {
      throw "Process Monitor exited before its configuration window became available"
    }
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    foreach ($window in $windows) {
      if ($window.Current.ProcessId -eq $Process.Id) { return $window }
    }
    if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
      return [System.Windows.Automation.AutomationElement]::FromHandle($Process.MainWindowHandle)
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Process Monitor did not expose its configuration window"
}

function Wait-FilterDialog([System.Diagnostics.Process]$Process, [System.Windows.Automation.AutomationElement]$MainWindow, [int]$TimeoutSeconds = 10) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $resetCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty,
    "Reset"
  )
  do {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    foreach ($window in $windows) {
      if ($window.Current.ProcessId -ne $Process.Id -or
        $window.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        continue
      }
      if ($null -ne $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)) {
        return $window
      }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Process Monitor filter dialog did not expose its Reset control"
}

function Select-ComboValue([System.Windows.Automation.AutomationElement]$Combo, [string]$Value) {
  $comboPattern = $Combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
  $comboPattern.Expand()
  try {
    $item = Wait-Element $Combo ([System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, $Value
    )) 5
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
  } finally {
    $comboPattern.Collapse()
  }
}

function Set-FilterRule([System.Windows.Automation.AutomationElement]$Dialog, [string]$Path) {
  $combos = $Dialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::ComboBox
    )
  )
  $edits = $Dialog.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit
    )
  )
  if ($combos.Count -lt 3 -or $edits.Count -lt 1) {
    throw "Process Monitor filter dialog has an unexpected control layout"
  }
  Select-ComboValue $combos[0] "Path"
  Select-ComboValue $combos[1] "is"
  $edits[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Path)
  Select-ComboValue $combos[2] "Include"
  $add = Wait-Element $Dialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Add"
  )) 5
  $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

try {
  $stage = "wait-for-input-idle"
  if (-not $process.WaitForInputIdle(10000)) {
    throw "Process Monitor UI did not become idle"
  }
  $stage = "find-main-window"
  $main = Wait-MainWindow $process
  $main.SetFocus()
  $stage = "activate-main-window"
  $mainHandle = [IntPtr]$main.Current.NativeWindowHandle
  if ($mainHandle -eq [IntPtr]::Zero -or -not [ProcmonWindowActivation]::SetForegroundWindow($mainHandle)) {
    throw "Process Monitor configuration window could not be activated"
  }
  $stage = "send-filter-shortcut"
  [System.Windows.Forms.SendKeys]::SendWait("^l")
  $stage = "wait-filter-dialog"
  $filterDialog = Wait-FilterDialog $process $main
  $stage = "reset-existing-filters"
  $reset = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Reset"
  )) 5
  $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  $stage = "set-canary-filter"
  Set-FilterRule $filterDialog $CanaryPath
  $stage = "set-control-filter"
  Set-FilterRule $filterDialog $ControlPath
  $stage = "apply-filters"
  $ok = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "OK"
  )) 5
  $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

  $stage = "enable-drop-filtered-events"
  $main.SetFocus()
  [System.Windows.Forms.SendKeys]::SendWait("%f")
  $drop = Wait-Element $main ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Drop Filtered Events"
  )) 5
  $toggle = $drop.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
  if ($toggle.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
    $toggle.Toggle()
  }
  if ($toggle.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
    throw "Process Monitor did not enable Drop Filtered Events"
  }

  $stage = "save-filter"
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
  [System.Windows.Forms.SendKeys]::SendWait("%f")
  $saveFilter = Wait-Element $main ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Save Filter..."
  )) 5
  $saveFilter.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  $saveDialog = Wait-TopLevelWindow "Save" 10
  $fileName = Wait-Element $saveDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Edit
  )) 5
  $fileName.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($ConfigPath)
  $save = Wait-Element $saveDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Save"
  )) 5
  $save.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  $stage = "verify-filter-file"
  if (-not (Test-Path -LiteralPath $ConfigPath) -or (Get-Item -LiteralPath $ConfigPath).Length -lt 100) {
    throw "Process Monitor did not save the audit filter configuration"
  }
} catch {
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILED_STAGE=$stage")
  exit 1
} finally {
  if (-not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(5000)) {
      Stop-Process -Id $process.Id -Force
    }
  }
}
