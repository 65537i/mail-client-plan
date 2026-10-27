param(
  [Parameter(Mandatory = $true)][int]$OwnerProcessId
)

$ErrorActionPreference = "Stop"
$stage = "load-automation"
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $stage = "find-capture-window"
  $process = [System.Diagnostics.Process]::GetProcessById($OwnerProcessId)
  $handle = $process.MainWindowHandle
  if ($process.HasExited -or $handle -eq [IntPtr]::Zero) {
    throw "Capture process has no main window"
  }
  $main = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
  if ($main.Current.ProcessId -ne $OwnerProcessId) {
    throw "Capture window belongs to a different process"
  }
  $stage = "scan-capture-controls"
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $pending = [System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]]::new()
  $pending.Enqueue($main)
  $matches = @{
    capture = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    filesystem = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  }
  $visited = 0
  while ($pending.Count -gt 0) {
    $item = $pending.Dequeue()
    $visited++
    if ($visited -gt 256) {
      throw "Capture UI scan exceeded its limit"
    }
    $state = $item.Current
    if ($state.ProcessId -ne $OwnerProcessId) {
      throw "Capture UI contains a foreign-process control"
    }
    $label = ($state.Name -replace "&", "") -replace "`t.*$", ""
    $target = switch -CaseSensitive ($label) {
      "Capture Events" { "capture" }
      "Capture (Ctrl+E)" { "capture" }
      "Show File System Activity" { "filesystem" }
    }
    if ($null -ne $target -and $state.ControlType -in @(
        [System.Windows.Automation.ControlType]::Button,
        [System.Windows.Automation.ControlType]::CheckBox,
        [System.Windows.Automation.ControlType]::MenuItem
      )) {
      $matches[$target].Add($item)
    }
    $child = $walker.GetFirstChild($item)
    while ($null -ne $child) {
      if ($visited + $pending.Count -ge 256) {
        throw "Capture UI scan exceeded its limit"
      }
      $pending.Enqueue($child)
      $child = $walker.GetNextSibling($child)
    }
  }
  $stage = "read-capture-control-patterns"
  foreach ($target in @("capture", "filesystem")) {
    $toggle = "unavailable"
    $selected = "unavailable"
    $enabled = "unavailable"
    $offscreen = "unavailable"
    if ($matches[$target].Count -eq 1) {
      $item = $matches[$target][0]
      $state = $item.Current
      if ($state.ProcessId -ne $OwnerProcessId) {
        throw "Capture control changed process ownership"
      }
      $enabled = $state.IsEnabled.ToString().ToLowerInvariant()
      $offscreen = $state.IsOffscreen.ToString().ToLowerInvariant()
      $pattern = $null
      if ($item.TryGetCurrentPattern(
          [System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern
        )) {
        $toggle = switch ($pattern.Current.ToggleState) {
          ([System.Windows.Automation.ToggleState]::On) { "on" }
          ([System.Windows.Automation.ToggleState]::Off) { "off" }
          ([System.Windows.Automation.ToggleState]::Indeterminate) { "mixed" }
          default { throw "Unknown capture toggle state" }
        }
      }
      $pattern = $null
      if ($item.TryGetCurrentPattern(
          [System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern
        )) {
        $selected = if ($pattern.Current.IsSelected) { "on" } else { "off" }
      }
    }
    [Console]::Out.WriteLine(
      "PROC_MON_CAPTURE_CONTROL=$target;matches:$($matches[$target].Count);toggle:$toggle;selected:$selected;enabled:$enabled;offscreen:$offscreen"
    )
  }
} catch {
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_FAILED_STAGE=$stage")
  exit 1
}
