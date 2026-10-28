param(
  [Parameter(Mandatory = $true)][int]$OwnerProcessId,
  [switch]$CountOnly
)

$ErrorActionPreference = "Stop"

function Get-ProcmonDriverEvidence {
  param([object[]]$Drivers)
  if ($Drivers.Count -gt 1024) {
    throw "System driver inventory exceeded its limit"
  }
  $candidates = 0
  $nameMatches = 0
  $imageMatches = 0
  $running = 0
  $started = 0
  $filesystem = 0
  $exitErrors = 0
  foreach ($driver in $Drivers) {
    if (
      $driver.Name -isnot [string] -or
      $driver.Name.Length -lt 1 -or
      $driver.Name.Length -gt 256 -or
      ($null -ne $driver.PathName -and $driver.PathName -isnot [string]) -or
      ($null -ne $driver.PathName -and $driver.PathName.Length -gt 2048)
    ) {
      throw "System driver inventory has an unsupported shape"
    }
    $nameMatch = $driver.Name -match '^PROCMON[0-9]*$'
    $imagePath = if ($null -eq $driver.PathName) { "" } else { $driver.PathName }
    $imageMatch = $imagePath -match '(?i)(?:^|[\\/])procmon[^\\/]*\.sys(?:[" ]|$)'
    if (-not $nameMatch -and -not $imageMatch) { continue }
    if (
      $driver.State -notin @(
        "Running", "Stopped", "Start Pending", "Stop Pending",
        "Continue Pending", "Pause Pending", "Paused", "Unknown"
      ) -or
      $driver.Started -isnot [bool] -or
      $driver.ServiceType -notin @(
        "Kernel Driver", "File System Driver", "Adapter", "Recognizer Driver"
      ) -or
      $driver.ExitCode -isnot [uint32]
    ) {
      throw "Procmon driver candidate has an unsupported shape"
    }
    $candidates++
    if ($nameMatch) { $nameMatches++ }
    if ($imageMatch) { $imageMatches++ }
    if ($driver.State -eq "Running") { $running++ }
    if ($driver.Started) { $started++ }
    if ($driver.ServiceType -eq "File System Driver") { $filesystem++ }
    if ($driver.ExitCode -ne 0) { $exitErrors++ }
  }
  return "inventory:$($Drivers.Count);candidates:$candidates;name-matches:$nameMatches;image-matches:$imageMatches;running:$running;started:$started;filesystem:$filesystem;exit-errors:$exitErrors"
}

$stage = "load-automation"
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName Accessibility
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

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", ExactSpelling = true)]
    private static extern IntPtr ReadListCount(
        IntPtr window, uint message, UIntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out UIntPtr result);

    public static string CountListItems(IntPtr window, uint ownerProcessId)
    {
        uint processId;
        if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out processId) == 0 ||
            processId != ownerProcessId)
            throw new InvalidOperationException("List ownership is unavailable");
        var name = new StringBuilder(256);
        if (GetClassName(window, name, name.Capacity) == 0 || name.ToString() != "SysListView32")
            throw new InvalidOperationException("Expected a native listview");
        UIntPtr result;
        if (ReadListCount(window, 0x1004, UIntPtr.Zero, IntPtr.Zero, 0x22, 2000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("List count query failed or timed out");
        if (GetWindowThreadProcessId(window, out processId) == 0 || processId != ownerProcessId)
            throw new InvalidOperationException("List ownership changed");
        ulong count = result.ToUInt64();
        if (count > Int32.MaxValue)
            throw new InvalidOperationException("List count is outside its supported range");
        return count.ToString(CultureInfo.InvariantCulture);
    }

    [DllImport("oleacc.dll", ExactSpelling = true)]
    private static extern int AccessibleObjectFromWindow(
        IntPtr window, uint objectId, ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out Accessibility.IAccessible accessible);

    private static string ReadToolbar(IntPtr toolbar, uint ownerProcessId, string target)
    {
        uint processId;
        if (GetWindowThreadProcessId(toolbar, out processId) == 0 || processId != ownerProcessId)
            throw new InvalidOperationException("Toolbar ownership is unavailable");
        var iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        Accessibility.IAccessible accessible;
        int result = AccessibleObjectFromWindow(toolbar, unchecked((uint)-4), ref iid, out accessible);
        if (result != 0 || accessible == null)
            return "object:unavailable;items:0;matches:0;checked:unavailable;enabled:unavailable";
        try
        {
            int count = accessible.accChildCount;
            if (count < 0 || count > 64)
                throw new InvalidOperationException("Toolbar accessible child count exceeds its limit");
            int matches = 0, matchedState = 0;
            for (int child = 1; child <= count; child++)
            {
                string name = (accessible.get_accName(child) ?? String.Empty).Replace("&", "");
                int accelerator = name.IndexOf('\t');
                if (accelerator >= 0) name = name.Substring(0, accelerator);
                bool match = target == "capture"
                    ? name == "Capture (Ctrl+E)" || name == "Capture Events"
                    : name == "Show File System Activity";
                if (!match) continue;
                object role = accessible.get_accRole(child);
                if (!(role is int) || ((int)role != 43 && (int)role != 44 && (int)role != 62))
                    throw new InvalidOperationException("Toolbar matched child role is unsupported");
                object state = accessible.get_accState(child);
                if (!(state is int))
                    throw new InvalidOperationException("Toolbar matched child state is unsupported");
                matches++;
                matchedState = (int)state;
            }
            if (GetWindowThreadProcessId(toolbar, out processId) == 0 || processId != ownerProcessId)
                throw new InvalidOperationException("Toolbar changed ownership");
            string check = matches != 1 ? "unavailable"
                : (matchedState & 0x20) != 0 ? "mixed"
                : (matchedState & 0x10) != 0 ? "on" : "off";
            string enabled = matches != 1 ? "unavailable" : (matchedState & 1) == 0 ? "true" : "false";
            return String.Format(CultureInfo.InvariantCulture,
                "object:available;items:{0};matches:{1};checked:{2};enabled:{3}", count, matches, check, enabled);
        }
        finally { Marshal.ReleaseComObject(accessible); }
    }

    public static string Inspect(IntPtr root, uint ownerProcessId)
    {
        uint rootProcessId;
        if (root == IntPtr.Zero || GetWindowThreadProcessId(root, out rootProcessId) == 0 ||
            rootProcessId != ownerProcessId)
            throw new InvalidOperationException("Native capture root ownership is unavailable");

        var seen = new HashSet<IntPtr>();
        IntPtr toolbar = IntPtr.Zero;
        IntPtr list = IntPtr.Zero;
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
                case "ToolbarWindow32": toolbars++; toolbar = window; break;
                case "SysListView32": lists++; list = window; break;
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
        string summary = String.Format(CultureInfo.InvariantCulture,
            "children:{0};visible:{1};toolbars:{2};lists:{3};statusbars:{4};dialogs:{5};other:{6}",
            seen.Count, visible, toolbars, lists, statusbars, dialogs, other);
        foreach (string target in new[] { "capture", "filesystem" })
        {
            string state = toolbars == 1 ? ReadToolbar(toolbar, ownerProcessId, target)
                : "object:unavailable;items:0;matches:0;checked:unavailable;enabled:unavailable";
            summary += "\nPROC_MON_CAPTURE_MSAA=" + target + ";" + state;
        }
        summary += "\nPROC_MON_CAPTURE_LIST=items:" +
            (lists == 1 ? CountListItems(list, ownerProcessId) : "unavailable");
        return summary;
    }
}
'@
  Add-Type -TypeDefinition $nativeCaptureType `
    -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location)
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
  if ($CountOnly) { exit 0 }
  $stage = "read-process-administrator-role"
  $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
  $administratorRole = $principal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
  ).ToString().ToLowerInvariant()
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_ADMINISTRATOR=$administratorRole")
  $stage = "query-system-driver-inventory"
  $drivers = @(
    Get-CimInstance -ClassName Win32_SystemDriver `
      -Property Name, PathName, State, Started, ServiceType, ExitCode -OperationTimeoutSec 5 |
      Select-Object -First 1025
  )
  $stage = "classify-system-driver-inventory"
  $driverEvidence = Get-ProcmonDriverEvidence $drivers
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_DRIVER=$driverEvidence")
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
  $failureType = $_.Exception.GetType().Name
  if ($failureType -notin @(
      "CimException",
      "ManagementException",
      "InvalidOperationException",
      "ParameterBindingException",
      "RuntimeException"
    )) {
    $failureType = "Other"
  }
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_FAILURE=$failureType")
  exit 1
}
