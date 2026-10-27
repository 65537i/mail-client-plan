param(
  [Parameter(Mandatory = $true)][int]$OwnerProcessId
)

$ErrorActionPreference = "Stop"
$stage = "load-automation"
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $stage = "compile-native-capture-helper"
  $nativeCaptureType = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

public static class ProcmonCaptureWindows
{
    private delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr window, StringBuilder name, int maximum);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindowVisible(IntPtr window);

    public static string Inspect(IntPtr root, uint ownerProcessId)
    {
        uint rootProcessId;
        if (root == IntPtr.Zero || GetWindowThreadProcessId(root, out rootProcessId) == 0 ||
            rootProcessId != ownerProcessId)
            throw new InvalidOperationException("Native capture root ownership is unavailable");

        var seen = new HashSet<IntPtr>();
        int toolbars = 0, lists = 0, statusbars = 0, dialogs = 0, other = 0, visible = 0;
        string failure = null;
        EnumWindowProc callback = delegate(IntPtr window, IntPtr parameter)
        {
            if (seen.Count >= 256 || !seen.Add(window))
            {
                failure = "Native capture child scan exceeded its limit or repeated a window";
                return false;
            }
            uint processId;
            if (GetWindowThreadProcessId(window, out processId) == 0 || processId != ownerProcessId)
            {
                failure = "Native capture child ownership is unavailable";
                return false;
            }
            var name = new StringBuilder(256);
            if (GetClassName(window, name, name.Capacity) == 0)
            {
                failure = "Native capture child class is unavailable";
                return false;
            }
            switch (name.ToString())
            {
                case "ToolbarWindow32": toolbars++; break;
                case "SysListView32": lists++; break;
                case "msctls_statusbar32": statusbars++; break;
                case "#32770": dialogs++; break;
                default: other++; break;
            }
            if (IsWindowVisible(window)) visible++;
            return true;
        };
        EnumChildWindows(root, callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        if (failure != null) throw new InvalidOperationException(failure);
        uint finalProcessId;
        if (GetWindowThreadProcessId(root, out finalProcessId) == 0 || finalProcessId != ownerProcessId)
            throw new InvalidOperationException("Native capture root changed ownership");
        return String.Format(CultureInfo.InvariantCulture,
            "children:{0};visible:{1};toolbars:{2};lists:{3};statusbars:{4};dialogs:{5};other:{6}",
            seen.Count, visible, toolbars, lists, statusbars, dialogs, other);
    }
}
'@
  Add-Type -TypeDefinition $nativeCaptureType
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
  $stage = "read-native-capture-children"
  $nativeChildren = [ProcmonCaptureWindows]::Inspect($handle, [uint32]$OwnerProcessId)
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_NATIVE=$nativeChildren")
  $visual = "unavailable"
  $windowPattern = $null
  if ($main.TryGetCurrentPattern(
      [System.Windows.Automation.WindowPattern]::Pattern, [ref]$windowPattern
    )) {
    $visual = switch ($windowPattern.Current.WindowVisualState) {
      ([System.Windows.Automation.WindowVisualState]::Normal) { "normal" }
      ([System.Windows.Automation.WindowVisualState]::Minimized) { "minimized" }
      ([System.Windows.Automation.WindowVisualState]::Maximized) { "maximized" }
      default { throw "Unknown capture window visual state" }
    }
  }
  $mainEnabled = $main.Current.IsEnabled.ToString().ToLowerInvariant()
  $mainOffscreen = $main.Current.IsOffscreen.ToString().ToLowerInvariant()
  $rootClass = if ($main.Current.ClassName -ceq "#32770") { "dialog" } else { "other" }
  $modal = if ($null -ne $windowPattern) {
    $windowPattern.Current.IsModal.ToString().ToLowerInvariant()
  } else { "unavailable" }
  $knownErrors = @{
    "Capture requires 64-bit mode." = "requires-64-bit"
    "Process Monitor is already monitoring this system." = "already-monitoring"
    "Capture requires Administrators group membership" = "requires-admin"
    "Another version of the Process Monitor driver is already loaded. A reboot is required to run this version." = "driver-version-conflict"
    "Unable to load Process Monitor device driver" = "driver-load"
    "Error enabling capture" = "enable-capture"
    "The selected configuration file cannot be opened" = "config-open"
  }
  $startupErrors = [System.Collections.Generic.HashSet[string]]::new()
  $stage = "scan-capture-controls"
  $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $pending = [System.Collections.Generic.Queue[System.Windows.Automation.AutomationElement]]::new()
  $pending.Enqueue($main)
  $matches = @{
    capture = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    filesystem = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  }
  $visited = 0
  $toolbars = 0
  $buttons = 0
  $menuitems = 0
  $texts = 0
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
    if ($state.ControlType.Equals([System.Windows.Automation.ControlType]::ToolBar)) {
      $toolbars++
    } elseif ($state.ControlType.Equals([System.Windows.Automation.ControlType]::Button)) {
      $buttons++
    } elseif ($state.ControlType.Equals([System.Windows.Automation.ControlType]::MenuItem)) {
      $menuitems++
    } elseif ($state.ControlType.Equals([System.Windows.Automation.ControlType]::Text)) {
      $texts++
    }
    foreach ($errorText in $knownErrors.Keys) {
      if ($state.Name -ceq $errorText) {
        $startupErrors.Add($knownErrors[$errorText]) | Out-Null
      }
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
  [Console]::Out.WriteLine(
    "PROC_MON_CAPTURE_WINDOW=visual:$visual;enabled:$mainEnabled;offscreen:$mainOffscreen;items:$visited;toolbars:$toolbars;buttons:$buttons;menuitems:$menuitems"
  )
  $startupError = if ($startupErrors.Count -eq 0) { "none" } elseif ($startupErrors.Count -eq 1) {
    @($startupErrors)[0]
  } else { "multiple" }
  [Console]::Out.WriteLine(
    "PROC_MON_CAPTURE_CONTEXT=class:$rootClass;modal:$modal;texts:$texts;startup-error:$startupError"
  )
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
