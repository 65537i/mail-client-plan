param(
  [Parameter(Mandatory = $true)][string]$ProcmonPath,
  [Parameter(Mandatory = $true)][string]$CanaryPath,
  [Parameter(Mandatory = $true)][string]$ControlPath,
  [Parameter(Mandatory = $true)][string]$ConfigPath
)

$ErrorActionPreference = "Stop"
function Write-StartupFailure([string]$FailedStage, $Failure) {
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILED_STAGE=$FailedStage")
  $failureType = $Failure.Exception.GetType().Name
  if ($failureType -notin @(
      "ArgumentException",
      "BadImageFormatException",
      "FileLoadException",
      "FileNotFoundException",
      "InvalidOperationException",
      "MethodInvocationException",
      "TypeInitializationException"
    )) {
    $failureType = "Other"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILURE=$failureType")
  if ($FailedStage -eq "compile-native-menu-helper") {
    $compileCode = [regex]::Match(
      $Failure.ToString(),
      "\bCS\d{4}\b"
    ).Value
    if ($compileCode -match "^CS\d{4}$") {
      [Console]::Out.WriteLine("PROC_MON_FILTER_COMPILE_ERROR=$compileCode")
    }
  }
}

try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  Add-Type -AssemblyName System.Windows.Forms
} catch {
  Write-StartupFailure "load-automation-assemblies" $_
  exit 1
}

try {
  Add-Type -AssemblyName Accessibility
} catch {
  Write-StartupFailure "load-msaa-assembly" $_
  exit 1
}

try {
  $nativeMenuTypeDefinition = @"
using System;
using System.Runtime.InteropServices;

public static class ProcmonNativeMenu
{
    private const uint MIIM_STATE = 0x00000001;
    private const uint MIIM_SUBMENU = 0x00000004;
    private const uint MIIM_STRING = 0x00000040;
    private const uint MIIM_FTYPE = 0x00000100;
    private const uint MFS_CHECKED = 0x00000008;
    private const uint MFT_OWNERDRAW = 0x00000100;
    private const uint MaximumTextCharacters = 255;
    private const int MaximumAccessibleMenuItems = 64;
    private const int MenuItemRole = 12;
    private const int CheckedState = 0x10;
    private const int MixedState = 0x20;

    [StructLayout(LayoutKind.Sequential)]
    private struct MenuItemInfo
    {
        public uint cbSize;
        public uint fMask;
        public uint fType;
        public uint fState;
        public uint wID;
        public IntPtr hSubMenu;
        public IntPtr hbmpChecked;
        public IntPtr hbmpUnchecked;
        public IntPtr dwItemData;
        public IntPtr dwTypeData;
        public uint cch;
        public IntPtr hbmpItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct GuiThreadInfo
    {
        public uint cbSize;
        public uint flags;
        public IntPtr hwndActive;
        public IntPtr hwndFocus;
        public IntPtr hwndCapture;
        public IntPtr hwndMenuOwner;
        public IntPtr hwndMoveSize;
        public IntPtr hwndCaret;
        public Rect rcCaret;
    }

    public sealed class ItemSnapshot
    {
        public string Text { get; set; }
        public bool IsChecked { get; set; }
        public IntPtr Submenu { get; set; }
    }

    public sealed class AccessibleMenuSnapshot
    {
        public bool ProcessKnown { get; set; }
        public bool ProcessSame { get; set; }
        public bool AccessibleAvailable { get; set; }
        public int ItemCount { get; set; }
        public int MatchCount { get; set; }
        public string ReadFailure { get; set; }
        public string CheckState { get; set; }
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetMenu(IntPtr hWnd);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static int GetWindowProcessId(IntPtr hWnd)
    {
        uint processId;
        return GetWindowThreadProcessId(hWnd, out processId) == 0
            ? 0
            : processId > int.MaxValue ? 0 : (int)processId;
    }

    [DllImport("user32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

    [DllImport("oleacc.dll", ExactSpelling = true)]
    private static extern int AccessibleObjectFromWindow(
        IntPtr hWnd,
        uint objectId,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out Accessibility.IAccessible accessibleObject
    );

    private static bool TryGetInteger(object value, out int number)
    {
        if (value is short)
        {
            number = (short)value;
            return true;
        }
        if (value is int)
        {
            number = (int)value;
            return true;
        }
        if (value is uint && (uint)value <= int.MaxValue)
        {
            number = (int)(uint)value;
            return true;
        }
        if (value is long && (long)value >= int.MinValue && (long)value <= int.MaxValue)
        {
            number = (int)(long)value;
            return true;
        }
        number = 0;
        return false;
    }

    public static AccessibleMenuSnapshot ReadAccessibleDropMenuState(
        IntPtr menuWindow,
        uint expectedProcessId
    )
    {
        var snapshot = new AccessibleMenuSnapshot
        {
            ReadFailure = "window-unavailable",
            CheckState = "unavailable"
        };
        uint menuProcessId;
        if (GetWindowThreadProcessId(menuWindow, out menuProcessId) == 0)
        {
            return snapshot;
        }
        snapshot.ProcessKnown = true;
        if (menuProcessId != expectedProcessId)
        {
            snapshot.ReadFailure = "process-mismatch";
            return snapshot;
        }
        snapshot.ProcessSame = true;

        var interfaceId = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        Accessibility.IAccessible accessibleObject;
        var result = AccessibleObjectFromWindow(
            menuWindow,
            unchecked((uint)-4),
            ref interfaceId,
            out accessibleObject
        );
        if (result != 0 || accessibleObject == null)
        {
            snapshot.ReadFailure = "object-unavailable";
            return snapshot;
        }
        snapshot.AccessibleAvailable = true;

        try
        {
            var itemCount = accessibleObject.accChildCount;
            if (itemCount < 0)
            {
                snapshot.ReadFailure = "count-invalid";
                return snapshot;
            }
            if (itemCount > MaximumAccessibleMenuItems)
            {
                snapshot.ReadFailure = "count-limit";
                return snapshot;
            }
            snapshot.ItemCount = itemCount;

            var matchState = 0;
            for (var childId = 1; childId <= itemCount; childId++)
            {
                var child = (object)childId;
                var name = accessibleObject.get_accName(child) ?? string.Empty;
                var roleValue = accessibleObject.get_accRole(child);
                int role;
                if (!TryGetInteger(roleValue, out role))
                {
                    snapshot.ReadFailure = "child-read-failed";
                    return snapshot;
                }
                if (role != MenuItemRole)
                {
                    continue;
                }

                var normalizedName = name.Replace("&", "");
                var acceleratorIndex = normalizedName.IndexOf('\t');
                if (acceleratorIndex >= 0)
                {
                    normalizedName = normalizedName.Substring(0, acceleratorIndex);
                }
                if (!string.Equals(
                    normalizedName.Trim(),
                    "Drop Filtered Events",
                    StringComparison.Ordinal
                ))
                {
                    continue;
                }

                snapshot.MatchCount++;
                var stateValue = accessibleObject.get_accState(child);
                int state;
                if (!TryGetInteger(stateValue, out state) || (state & MixedState) != 0)
                {
                    snapshot.ReadFailure = "state-invalid";
                    return snapshot;
                }
                matchState = state;
            }

            if (snapshot.MatchCount == 0)
            {
                snapshot.ReadFailure = "no-match";
                return snapshot;
            }
            if (snapshot.MatchCount != 1)
            {
                snapshot.ReadFailure = "duplicate-match";
                return snapshot;
            }
            snapshot.ReadFailure = "none";
            snapshot.CheckState = (matchState & CheckedState) != 0 ? "on" : "off";
            return snapshot;
        }
        catch (COMException)
        {
            snapshot.ReadFailure = "child-read-failed";
            return snapshot;
        }
    }

    public static IntPtr GetMenuOwnerWindow(
        IntPtr menuWindow,
        uint expectedProcessId,
        out bool menuWindowProcessKnown,
        out bool menuWindowSameProcess,
        out bool guiThreadInfoAvailable
    )
    {
        menuWindowProcessKnown = false;
        menuWindowSameProcess = false;
        guiThreadInfoAvailable = false;
        uint menuProcessId;
        var menuThreadId = GetWindowThreadProcessId(menuWindow, out menuProcessId);
        if (menuThreadId == 0)
        {
            return IntPtr.Zero;
        }
        menuWindowProcessKnown = true;
        if (menuProcessId != expectedProcessId)
        {
            return IntPtr.Zero;
        }
        menuWindowSameProcess = true;

        var info = new GuiThreadInfo
        {
            cbSize = (uint)Marshal.SizeOf(typeof(GuiThreadInfo))
        };
        if (!GetGUIThreadInfo(menuThreadId, ref info))
        {
            return IntPtr.Zero;
        }
        guiThreadInfoAvailable = true;
        if (info.hwndMenuOwner == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        uint ownerProcessId;
        if (
            GetWindowThreadProcessId(info.hwndMenuOwner, out ownerProcessId) == 0 ||
            ownerProcessId != expectedProcessId
        )
        {
            return IntPtr.Zero;
        }
        return info.hwndMenuOwner;
    }

    [DllImport(
        "user32.dll",
        EntryPoint = "GetMenuItemCount",
        ExactSpelling = true,
        SetLastError = true
    )]
    private static extern int GetMenuItemCountNative(IntPtr hMenu);

    public static int GetMenuItemCount(IntPtr hMenu)
    {
        var itemCount = GetMenuItemCountNative(hMenu);
        if (itemCount >= 0)
        {
            return itemCount;
        }
        var lastError = Marshal.GetLastWin32Error();
        return lastError == 1401 ? -2 : lastError == 0 ? -3 : -4;
    }

    [DllImport(
        "user32.dll",
        EntryPoint = "GetMenuItemInfoW",
        ExactSpelling = true,
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMenuItemInfo(
        IntPtr hMenu,
        uint item,
        [MarshalAs(UnmanagedType.Bool)] bool fByPosition,
        ref MenuItemInfo info
    );

    public static ItemSnapshot ReadItem(IntPtr hMenu, uint position, out bool ownerDrawn)
    {
        ownerDrawn = false;
        var info = new MenuItemInfo
        {
            cbSize = (uint)Marshal.SizeOf(typeof(MenuItemInfo)),
            fMask = MIIM_STATE | MIIM_SUBMENU | MIIM_FTYPE
        };
        if (!GetMenuItemInfo(hMenu, position, true, ref info))
        {
            return null;
        }
        ownerDrawn = (info.fType & MFT_OWNERDRAW) != 0;
        if (ownerDrawn)
        {
            return null;
        }
        info.fMask = MIIM_STRING;
        info.dwTypeData = IntPtr.Zero;
        info.cch = 0;
        if (!GetMenuItemInfo(hMenu, position, true, ref info) ||
            info.cch > MaximumTextCharacters)
        {
            return null;
        }
        var bufferCharacters = info.cch + 1;
        var buffer = Marshal.AllocHGlobal((int)(bufferCharacters * 2));
        try
        {
            info.dwTypeData = buffer;
            info.cch = bufferCharacters;
            if (!GetMenuItemInfo(hMenu, position, true, ref info) ||
                info.cch > MaximumTextCharacters)
            {
                return null;
            }
            return new ItemSnapshot
            {
                Text = Marshal.PtrToStringUni(buffer, (int)info.cch) ?? string.Empty,
                IsChecked = (info.fState & MFS_CHECKED) != 0,
                Submenu = info.hSubMenu
            };
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
"@
  Add-Type -TypeDefinition $nativeMenuTypeDefinition `
    -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location)
} catch {
  Write-StartupFailure "compile-native-menu-helper" $_
  exit 1
}

try {
  $process = Start-Process -FilePath $ProcmonPath -ArgumentList "/AcceptEula" -PassThru
} catch {
  Write-StartupFailure "start-procmon" $_
  exit 1
}

function Set-Stage([string]$Name) {
  $script:stage = $Name
  [Console]::Out.WriteLine("PROC_MON_FILTER_PROGRESS=$Name")
}

function Get-ConfigHeaderClass([string]$Path) {
  $stream = [System.IO.File]::OpenRead($Path)
  try {
    $header = [byte[]]::new(8)
    $length = $stream.Read($header, 0, $header.Length)
  } finally {
    $stream.Dispose()
  }
  if ($length -eq 0) { return "empty" }
  if ($length -lt 4) { return "short" }
  if ($header[0] -eq 0x4d -and $header[1] -eq 0x5a) { return "mz" }
  if ([System.Text.Encoding]::ASCII.GetString($header, 0, $length).StartsWith(
      "<?xml", [System.StringComparison]::Ordinal
    )) {
    return "xml"
  }
  return "other"
}

function Write-ConfigOutputObservation([string]$Phase, [string]$Path) {
  $targetState = "missing"
  $targetHeader = "not-file"
  if (Test-Path -LiteralPath $Path) {
    $target = Get-Item -LiteralPath $Path
    $targetState = if ($target.PSIsContainer) {
      "directory"
    } elseif ($target.Length -lt 100) {
      "undersized"
    } else {
      "ready"
    }
    if (-not $target.PSIsContainer) {
      $targetHeader = Get-ConfigHeaderClass $Path
    }
  }
  $pmcCount = 0
  $headerCounts = @{
    empty = 0
    short = 0
    mz = 0
    xml = 0
    other = 0
  }
  $otherCount = 0
  $entries = @(
    Get-ChildItem -LiteralPath ([System.IO.Path]::GetDirectoryName($Path)) -Force |
      Select-Object -First 33
  )
  $truncated = ($entries.Count -gt 32)
  foreach ($entry in $entries | Select-Object -First 32) {
    if ($entry.PSIsContainer) {
      $otherCount++
    } elseif ($entry.Extension -ieq ".pmc") {
      $pmcCount++
      $headerCounts[(Get-ConfigHeaderClass $entry.FullName)]++
    } else {
      $otherCount++
    }
  }
  $headerSummary = "empty:$($headerCounts.empty);short:$($headerCounts.short);mz:$($headerCounts.mz);xml:$($headerCounts.xml);other:$($headerCounts.other)"
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_CONFIG_OUTPUT=phase:$Phase;target:$targetState;target-header:$targetHeader;pmc-count:$pmcCount;headers:$headerSummary;other-count:$otherCount;truncated:$($truncated.ToString().ToLowerInvariant())"
  )
}

function Wait-Element([System.Windows.Automation.AutomationElement]$Root, [System.Windows.Automation.Condition]$Condition, [int]$TimeoutSeconds = 10) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $element = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $Condition)
    if ($null -ne $element) { return $element }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out waiting for a Process Monitor UI control"
}

function Wait-FilterConfigFile([string]$Path, [int]$TimeoutMilliseconds = 5000) {
  $timer = [System.Diagnostics.Stopwatch]::StartNew()
  $firstObservation = $true
  do {
    $state = "missing"
    if (Test-Path -LiteralPath $Path) {
      $file = Get-Item -LiteralPath $Path
      if ($file.PSIsContainer) {
        throw "Process Monitor configuration path is not a file"
      }
      $state = if ($file.Length -ge 100) { "ready" } else { "undersized" }
    }
    if ($firstObservation) {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:initial;state:$state")
      $firstObservation = $false
    }
    if ($state -eq "ready") {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:final;state:ready")
      return
    }
    $remaining = $TimeoutMilliseconds - $timer.ElapsedMilliseconds
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min(100, $remaining))
  } while ($true)
  [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_FILE=observation:final;state:$state")
  throw "Process Monitor did not save the audit filter configuration before the deadline"
}

function Wait-ConfigSaveFocus($Save, [int]$TimeoutMilliseconds = 2000) {
  $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
  do {
    $state = $Save.Current
    if ($state.HasKeyboardFocus) {
      return $state
    }
    $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min(50, $remaining))
  } while ([DateTime]::UtcNow -lt $deadline)
  return $null
}

function Write-ConfigSaveObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Controls,
  [int]$OwnerProcessId,
  [string]$ExpectedPath
) {
  try {
    $dialogState = $Controls.Dialog.Current
    $fileNameState = $Controls.FileName.Current
    $saveState = $Controls.Save.Current
    if ($dialogState.ProcessId -ne $OwnerProcessId -or
      $fileNameState.ProcessId -ne $OwnerProcessId -or
      $saveState.ProcessId -ne $OwnerProcessId) {
      [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:other-process")
      return
    }
    $pathState = if (
      $Controls.FileName.GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern
      ).Current.Value -ceq $ExpectedPath
    ) { "matches" } else { "different" }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:available;enabled:$($dialogState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dialogState.IsOffscreen.ToString().ToLowerInvariant());path:$pathState;save-enabled:$($saveState.IsEnabled.ToString().ToLowerInvariant());save-offscreen:$($saveState.IsOffscreen.ToString().ToLowerInvariant());save-focusable:$($saveState.IsKeyboardFocusable.ToString().ToLowerInvariant());save-focused:$($saveState.HasKeyboardFocus.ToString().ToLowerInvariant())"
    )
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_CONFIG_SAVE=$Phase;dialog:unavailable")
  }
}

function Wait-ConfigSaveDialog(
  [System.Diagnostics.Process]$Process,
  [System.Windows.Automation.AutomationElement]$MainWindow,
  [int]$TimeoutSeconds = 10
) {
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Window
  )
  $fileNameCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Edit
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "File name:"
    )
  )
  $saveCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Save"
    )
  )
  do {
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      $windowCondition
    )
    $embeddedWindows = $MainWindow.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      $windowCondition
    )
    $seenHandles = [System.Collections.Generic.HashSet[int]]::new()
    $matches = [System.Collections.Generic.List[object]]::new()
    $fileNameCount = 0
    $saveCount = 0
    foreach ($window in @($windows) + @($embeddedWindows)) {
      $state = $window.Current
      if ($state.ProcessId -ne $Process.Id -or
        $state.NativeWindowHandle -eq 0 -or
        $state.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle -or
        -not $state.IsEnabled -or $state.IsOffscreen -or
        -not $seenHandles.Add($state.NativeWindowHandle)) {
        continue
      }
      $fileNames = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $fileNameCondition
      )
      $saveButtons = $window.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $saveCondition
      )
      $fileNameCount += $fileNames.Count
      $saveCount += $saveButtons.Count
      if ($fileNames.Count -eq 1 -and $saveButtons.Count -eq 1) {
        $matches.Add(@{ Dialog = $window; FileName = $fileNames[0]; Save = $saveButtons[0] })
      }
    }
    if ($matches.Count -gt 1) {
      throw "Process Monitor exposed multiple configuration save dialogs"
    }
    if ($matches.Count -eq 1) {
      return $matches[0]
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SAVE_DIALOG_SCAN=windows:$([Math]::Min($seenHandles.Count, 9999));file-names:$([Math]::Min($fileNameCount, 9999));save-buttons:$([Math]::Min($saveCount, 9999))"
  )
  throw "Process Monitor configuration save dialog did not expose unique file controls"
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
  $processWindowCount = 0
  $nonMainWindowCount = 0
  $resetControlPresent = $false
  $desktopResetOwner = "none"
  $desktopResetTree = [System.Collections.Generic.List[string]]::new()
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
    $processWindowCount = 0
    $nonMainWindowCount = 0
    $resetControlPresent = $false
    foreach ($window in $windows) {
      if ($window.Current.ProcessId -ne $Process.Id) {
        continue
      }
      $processWindowCount++
      if ($window.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        continue
      }
      $nonMainWindowCount++
      if ($null -ne $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)) {
        $resetControlPresent = $true
        return $window
      }
    }
    $mainReset = $MainWindow.FindFirst(
      [System.Windows.Automation.TreeScope]::Descendants,
      $resetCondition
    )
    if ($null -ne $mainReset) {
      $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $candidateWindow = $mainReset
      for ($level = 0; $null -ne $candidateWindow -and $level -lt 8; $level++) {
        $candidateState = $candidateWindow.Current
        if (
          $candidateState.ControlType -eq [System.Windows.Automation.ControlType]::Window -and
          $candidateState.ProcessId -eq $Process.Id -and
          $candidateState.NativeWindowHandle -ne 0 -and
          $candidateState.NativeWindowHandle -ne $MainWindow.Current.NativeWindowHandle
        ) {
          $candidateCombos = $candidateWindow.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
              [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
              [System.Windows.Automation.ControlType]::ComboBox
            )
          )
          $candidateEdits = $candidateWindow.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
              [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
              [System.Windows.Automation.ControlType]::Edit
            )
          )
          if (
            $null -ne $candidateWindow.FindFirst(
              [System.Windows.Automation.TreeScope]::Descendants,
              $resetCondition
            ) -and
            $candidateCombos.Count -ge 3 -and
            $candidateEdits.Count -ge 1
          ) {
            $comboCount = [Math]::Min($candidateCombos.Count, 9999)
            $editCount = [Math]::Min($candidateEdits.Count, 9999)
            [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_DISCOVERY=embedded-window")
            [Console]::Out.WriteLine(
              "PROC_MON_FILTER_DIALOG_LAYOUT=combos:$comboCount;edits:$editCount"
            )
            return $candidateWindow
          }
        }
        $candidateWindow = $treeWalker.GetParent($candidateWindow)
      }
    }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  foreach ($window in $windows) {
    $reset = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)
    if ($null -ne $reset) {
      if ($window.Current.ProcessId -ne $Process.Id) {
        $desktopResetOwner = "other-process"
      } elseif ($window.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
        $desktopResetOwner = "procmon-main"
      } else {
        $desktopResetOwner = "procmon-other"
      }
      $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
      $treeNode = $reset
      for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
        $desktopResetTree.Add((Get-ControlTypeLabel $treeNode))
        $treeNode = $treeWalker.GetParent($treeNode)
      }
      break
    }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_SCAN=process-windows:$processWindowCount;non-main-windows:$nonMainWindowCount;reset-control:$($resetControlPresent.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DIALOG_DESKTOP_RESET_OWNER=$desktopResetOwner"
  )
  if ($desktopResetTree.Count -gt 0) {
    [Console]::Out.WriteLine("PROC_MON_FILTER_DIALOG_RESET_TREE=$($desktopResetTree -join '>')")
  }
  throw "Process Monitor filter dialog did not expose its Reset control"
}

function Find-NativeDropMenuItem([System.IntPtr]$MenuHandle, [int]$Depth) {
  if ($Depth -gt 4 -or $script:nativeMenuVisited -ge 256) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = if ($Depth -gt 4) { "depth-limit" } else { "total-limit" }
    }
    return
  }
  Set-Stage "invoke-native-menu-count"
  $itemCount = [ProcmonNativeMenu]::GetMenuItemCount($MenuHandle)
  Set-Stage "classify-native-menu-count"
  if ($itemCount -lt 0) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = if ($itemCount -eq -2) {
        "invalid-menu-handle"
      } elseif ($itemCount -eq -3) {
        "menu-count-invalid"
      } else {
        "menu-count-failed"
      }
    }
    return
  }
  if ($itemCount -gt 64) {
    $script:nativeMenuReadable = $false
    if ($script:nativeMenuFailure -eq "none") {
      $script:nativeMenuFailure = "menu-count-limit"
    }
    return
  }
  for ($position = 0; $position -lt $itemCount; $position++) {
    if ($script:nativeMenuVisited -ge 256) {
      $script:nativeMenuReadable = $false
      if ($script:nativeMenuFailure -eq "none") {
        $script:nativeMenuFailure = "total-limit"
      }
      return
    }
    $ownerDrawn = $false
    $item = [ProcmonNativeMenu]::ReadItem(
      $MenuHandle,
      [uint32]$position,
      [ref]$ownerDrawn
    )
    if ($null -eq $item) {
      $script:nativeMenuReadable = $false
      if ($script:nativeMenuFailure -eq "none") {
        $script:nativeMenuFailure = if ($ownerDrawn) { "owner-drawn" } else { "item-read-failed" }
      }
      continue
    }
    $script:nativeMenuVisited++
    $itemName = $item.Text.Replace("&", "")
    $acceleratorIndex = $itemName.IndexOf("`t")
    if ($acceleratorIndex -ge 0) {
      $itemName = $itemName.Substring(0, $acceleratorIndex)
    }
    $itemName = $itemName.Trim()
    if ([string]::Equals(
        $itemName,
        "Drop Filtered Events",
        [System.StringComparison]::Ordinal
      )) {
      $script:nativeDropMenuMatches.Add([bool]$item.IsChecked)
    }
    if (-not $item.Submenu.Equals([System.IntPtr]::Zero)) {
      Find-NativeDropMenuItem $item.Submenu ($Depth + 1)
    }
  }
}

function Get-NativeDropMenuSnapshot(
  [System.IntPtr]$WindowHandle,
  [System.IntPtr]$MenuWindowHandle,
  [uint32]$ProcessId
) {
  Set-Stage "get-native-menu-handle"
  $menuHandle = [ProcmonNativeMenu]::GetMenu($WindowHandle)
  $menuSource = "main"
  $menuOwnerWindowHandle = [System.IntPtr]::Zero
  $menuWindowProcessKnown = $false
  $menuWindowSameProcess = $false
  $guiThreadInfoAvailable = $false
  if ($menuHandle.Equals([System.IntPtr]::Zero)) {
    $menuOwnerWindowHandle = [ProcmonNativeMenu]::GetMenuOwnerWindow(
      $MenuWindowHandle,
      $ProcessId,
      [ref]$menuWindowProcessKnown,
      [ref]$menuWindowSameProcess,
      [ref]$guiThreadInfoAvailable
    )
    if (-not $menuOwnerWindowHandle.Equals([System.IntPtr]::Zero)) {
      $menuHandle = [ProcmonNativeMenu]::GetMenu($MenuWindowHandle)
      if ($menuHandle.Equals([System.IntPtr]::Zero)) {
        $menuHandle = [ProcmonNativeMenu]::GetMenu($menuOwnerWindowHandle)
        if ($menuHandle.Equals([System.IntPtr]::Zero)) {
          $menuSource = "unavailable"
        } else {
          $menuSource = "menu-owner"
        }
      } else {
        $menuSource = "menu-window"
      }
    } else {
      $menuSource = "unavailable"
    }
  }
  $handleAvailable = -not $menuHandle.Equals([System.IntPtr]::Zero)
  $script:nativeMenuVisited = 0
  $script:nativeMenuReadable = $handleAvailable
  $script:nativeMenuFailure = "none"
  $script:nativeDropMenuMatches = [System.Collections.Generic.List[bool]]::new()
  if ($handleAvailable) {
    Set-Stage "scan-native-menu-state"
    Find-NativeDropMenuItem $menuHandle 0
  }
  Set-Stage "report-native-menu-state"
  $checkState = "unavailable"
  if ($script:nativeMenuReadable -and $script:nativeDropMenuMatches.Count -eq 1) {
    $checkState = if ($script:nativeDropMenuMatches[0]) { "on" } else { "off" }
  }
  [pscustomobject]@{
    MenuSource = $menuSource
    MenuWindowProcess = if (-not $menuWindowProcessKnown) { "unavailable" } elseif ($menuWindowSameProcess) { "same" } else { "other" }
    GuiThreadInfoAvailable = $guiThreadInfoAvailable
    OwnerWindowAvailable = -not $menuOwnerWindowHandle.Equals([System.IntPtr]::Zero)
    HandleAvailable = $handleAvailable
    ItemCount = [Math]::Min($script:nativeMenuVisited, 9999)
    MatchCount = [Math]::Min($script:nativeDropMenuMatches.Count, 9999)
    ReadFailure = $script:nativeMenuFailure
    Readable = $script:nativeMenuReadable
    CheckState = $checkState
  }
}

function Write-NativeDropMenuSnapshot($Snapshot, [string]$Observation) {
  $guiThreadInfoState = if ($Snapshot.GuiThreadInfoAvailable) { "available" } else { "unavailable" }
  $ownerWindowState = if ($Snapshot.OwnerWindowAvailable) { "available" } else { "unavailable" }
  $handleState = if ($Snapshot.HandleAvailable) { "available" } else { "unavailable" }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_NATIVE_MENU_STATE=observation:$Observation;source:$($Snapshot.MenuSource);menu-window-process:$($Snapshot.MenuWindowProcess);gui-thread-info:$guiThreadInfoState;owner-window:$ownerWindowState;handle:$handleState;items:$($Snapshot.ItemCount);matches:$($Snapshot.MatchCount);read-failure:$($Snapshot.ReadFailure);readable:$($Snapshot.Readable.ToString().ToLowerInvariant());checked:$($Snapshot.CheckState)"
  )
}

function Get-AccessibleDropMenuSnapshot(
  [System.IntPtr]$MenuWindowHandle,
  [uint32]$ProcessId,
  [string]$Observation
) {
  Set-Stage "invoke-msaa-menu-state"
  $snapshot = [ProcmonNativeMenu]::ReadAccessibleDropMenuState(
    $MenuWindowHandle,
    $ProcessId
  )
  Set-Stage "report-msaa-menu-state"
  $processState = if (-not $snapshot.ProcessKnown) {
    "unavailable"
  } elseif ($snapshot.ProcessSame) {
    "same"
  } else {
    "other"
  }
  $objectState = if ($snapshot.AccessibleAvailable) { "available" } else { "unavailable" }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MSAA_MENU_STATE=observation:$Observation;process:$processState;object:$objectState;items:$($snapshot.ItemCount);matches:$($snapshot.MatchCount);read-failure:$($snapshot.ReadFailure);checked:$($snapshot.CheckState)"
  )
  return $snapshot
}

function Get-VerifiedDropMenuCheckState($NativeSnapshot, $AccessibleSnapshot) {
  if ($NativeSnapshot.CheckState -in @("on", "off")) {
    return $NativeSnapshot.CheckState
  }
  if (
    $null -ne $AccessibleSnapshot -and
    $AccessibleSnapshot.CheckState -in @("on", "off")
  ) {
    return $AccessibleSnapshot.CheckState
  }
  return "unavailable"
}

function Find-ComboValue(
  [System.Windows.Automation.AutomationElement]$Combo,
  [string]$Value,
  [int]$TimeoutSeconds = 1
) {
  $comboPattern = $null
  if (-not $Combo.TryGetCurrentPattern(
      [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
      [ref]$comboPattern
    )) {
    return $null
  }
  $condition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, $Value
  )
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  $comboPattern.Expand()
  try {
    do {
      $item = $Combo.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
      if ($null -ne $item) { return $item }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
  } finally {
    $comboPattern.Collapse()
  }
}

function Select-ComboValue($Combos, [string]$Value) {
  $matchingCombos = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  $optionLabel = switch ($Value) {
    "Path" { "column" }
    "is" { "operator" }
    "Include" { "action" }
    default { "other" }
  }
  $index = 0
  foreach ($combo in $Combos) {
    $ordinal = switch ($index) {
      0 { "one" }
      1 { "two" }
      2 { "three" }
      3 { "four" }
      4 { "five" }
      5 { "six" }
      6 { "seven" }
      7 { "eight" }
      default { "many" }
    }
    Set-Stage "probe-$optionLabel-combo-$ordinal"
    if ($null -ne (Find-ComboValue $combo $Value)) {
      $matchingCombos.Add($combo)
    }
    $index++
  }
  if ($matchingCombos.Count -ne 1) {
    throw "Process Monitor filter dialog did not expose one exact option"
  }
  Set-Stage "expand-$optionLabel-combo"
  $comboPattern = $matchingCombos[0].GetCurrentPattern(
    [System.Windows.Automation.ExpandCollapsePattern]::Pattern
  )
  $comboPattern.Expand()
  try {
    Set-Stage "wait-$optionLabel-option"
    $item = Wait-Element $matchingCombos[0] ([System.Windows.Automation.PropertyCondition]::new(
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
  Set-Stage "select-filter-column"
  Select-ComboValue $combos "Path"
  Set-Stage "select-filter-operator"
  Select-ComboValue $combos "is"
  Set-Stage "probe-filter-path-edit"
  $editState = $edits[0].Current
  $valuePattern = $null
  $hasValuePattern = $edits[0].TryGetCurrentPattern(
    [System.Windows.Automation.ValuePattern]::Pattern,
    [ref]$valuePattern
  )
  $isReadOnly = $true
  if ($hasValuePattern) {
    $isReadOnly = $valuePattern.Current.IsReadOnly
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_PATH_EDIT=enabled:$($editState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($editState.IsOffscreen.ToString().ToLowerInvariant());read-only:$($isReadOnly.ToString().ToLowerInvariant());value-pattern:$($hasValuePattern.ToString().ToLowerInvariant())"
  )
  if (-not $editState.IsEnabled -or
    $editState.IsOffscreen -or
    -not $hasValuePattern -or
    $isReadOnly) {
    throw "Process Monitor filter path field is not writable"
  }
  Set-Stage "set-filter-path-value"
  $valuePattern.SetValue($Path)
  Set-Stage "select-filter-action"
  Select-ComboValue $combos "Include"
  Set-Stage "add-filter-rule"
  $add = Wait-Element $Dialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Add"
  )) 5
  $add.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Get-ControlTypeLabel([System.Windows.Automation.AutomationElement]$Element) {
  switch ($Element.Current.ControlType.ProgrammaticName) {
    "ControlType.MenuBar" { return "MenuBar" }
    "ControlType.Menu" { return "Menu" }
    "ControlType.MenuItem" { return "MenuItem" }
    "ControlType.Window" { return "Window" }
    "ControlType.Pane" { return "Pane" }
    "ControlType.ToolBar" { return "ToolBar" }
    "ControlType.Button" { return "Button" }
    "ControlType.Text" { return "Text" }
    "ControlType.Edit" { return "Edit" }
    default { return "Other" }
  }
}

function Get-ControlNameLabel([System.Windows.Automation.AutomationElement]$Element) {
  switch ($Element.Current.Name) {
    "File" { return "FileMenu" }
    "Filter" { return "Filter" }
    "Filter..." { return "FilterCommand" }
    "Save Filter..." { return "SaveFilterCommand" }
    "Export Configuration..." { return "ExportConfigCommand" }
    "Drop Filtered Events" { return "DropFilteredEvents" }
    "Highlight Filtered Events" { return "HighlightFilteredEvents" }
    "Menu Bar" { return "MenuBar" }
    "Process Monitor" { return "ProcessMonitor" }
    default { return "Other" }
  }
}

function Write-MenuItemsObservation(
  [string]$Phase,
  [System.Windows.Automation.AutomationElement]$Menu
) {
  try {
    $items = $Menu.FindAll(
      [System.Windows.Automation.TreeScope]::Children,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $observedItems = [System.Collections.Generic.List[string]]::new()
    $itemLimit = [Math]::Min($items.Count, 8)
    for ($index = 0; $index -lt $itemLimit; $index++) {
      $item = $items[$index]
      $state = $item.Current
      $observedItems.Add(
        "$(Get-ControlTypeLabel $item):$(Get-ControlNameLabel $item):$($state.IsEnabled.ToString().ToLowerInvariant()):$($state.IsOffscreen.ToString().ToLowerInvariant()):$($state.IsKeyboardFocusable.ToString().ToLowerInvariant())"
      )
    }
    $truncated = ($items.Count -gt $itemLimit).ToString().ToLowerInvariant()
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_MENU_ITEMS=$Phase;count:$($items.Count);truncated:$truncated;items=$($observedItems -join ',')"
    )
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_ITEMS=$Phase;unavailable")
  }
}

function Write-FocusSnapshotObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Snapshot
) {
  $elementState = if ($null -eq $Snapshot["Element"]) { "missing" } else { "present" }
  $controlType = switch ($Snapshot["ControlType"]) {
    "ControlType.Menu" { "menu" }
    "ControlType.MenuItem" { "menu-item" }
    "ControlType.Window" { "window" }
    "ControlType.Pane" { "pane" }
    "ControlType.ToolBar" { "toolbar" }
    $null { "missing" }
    default { "other" }
  }
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_SNAPSHOT=$Phase;element:$elementState;control-type:$controlType"
  )
}

function Write-FocusObservation(
  [string]$Phase,
  [System.Collections.IDictionary]$Snapshot = $null
) {
  if ($null -ne $Snapshot) {
    $Snapshot["Element"] = $null
    $Snapshot["ControlType"] = $null
  }
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $focused) {
      if ($null -ne $Snapshot) {
        Write-FocusSnapshotObservation "writer" $Snapshot
      }
      [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;focused:none")
      return
    }
    $state = $focused.Current
    $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $treeParts = [System.Collections.Generic.List[string]]::new()
    $treeNode = $focused
    for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
      $treeParts.Add("$(Get-ControlTypeLabel $treeNode):$(Get-ControlNameLabel $treeNode)")
      $treeNode = $treeWalker.GetParent($treeNode)
    }
    if ($null -ne $Snapshot) {
      $Snapshot["Element"] = $focused
      $Snapshot["ControlType"] = $state.ControlType.ProgrammaticName
    }
    if ($null -ne $Snapshot) {
      Write-FocusSnapshotObservation "writer" $Snapshot
    }
    [Console]::Out.WriteLine(
      "PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;type:$(Get-ControlTypeLabel $focused);name:$(Get-ControlNameLabel $focused);offscreen:$($state.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($state.IsKeyboardFocusable.ToString().ToLowerInvariant());tree=$($treeParts -join '>')"
    )
    if (
      $Phase -in @("after-open", "after-home") -and
      $state.ControlType.ProgrammaticName -eq "ControlType.Menu"
    ) {
      Write-MenuItemsObservation $Phase $focused
    }
  } catch {
    [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUSED_CONTROL=$Phase;focused:unavailable")
  }
}

function Write-FocusOwnerObservation(
  [string]$Phase,
  [System.Diagnostics.Process]$Process,
  [System.Windows.Automation.AutomationElement]$MainWindow
) {
  $owner = "unavailable"
  $reason = $null
  try {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    for ($level = 0; $null -ne $focused -and $level -lt 4; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window) {
        if ($focused.Current.ProcessId -ne $Process.Id) {
          $owner = "other-process"
        } elseif ($focused.Current.NativeWindowHandle -eq $MainWindow.Current.NativeWindowHandle) {
          $owner = "procmon-main"
        } else {
          $owner = "procmon-other"
        }
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -eq $focused) {
      $owner = "no-window"
    }
  } catch {
    $reason = $_.Exception.GetType().Name
    if ($reason -notin @(
        "ElementNotAvailableException",
        "InvalidOperationException",
        "COMException"
      )) {
      $reason = "Other"
    }
  }
  $suffix = if ($null -eq $reason) { "" } else { ";reason:$reason" }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FOCUS_OWNER=$Phase;owner:$owner$suffix")
}

try {
  Set-Stage "wait-for-input-idle"
  if (-not $process.WaitForInputIdle(10000)) {
    throw "Process Monitor UI did not become idle"
  }
  Set-Stage "find-main-window"
  $main = Wait-MainWindow $process
  $main.SetFocus()
  Set-Stage "find-filter-menu"
  $filterMenuCondition = [System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )
  $filterMenu = Wait-Element $main $filterMenuCondition 5
  Set-Stage "focus-filter-menu"
  $menuState = $filterMenu.Current
  $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  $treeParts = [System.Collections.Generic.List[string]]::new()
  $treeNode = $filterMenu
  for ($level = 0; $null -ne $treeNode -and $level -lt 4; $level++) {
    $treeParts.Add("$(Get-ControlTypeLabel $treeNode):$(Get-ControlNameLabel $treeNode)")
    $treeNode = $treeWalker.GetParent($treeNode)
  }
  $expandPattern = $null
  $hasExpandPattern = $filterMenu.TryGetCurrentPattern(
    [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
    [ref]$expandPattern
  )
  $invokePattern = $null
  $hasInvokePattern = $filterMenu.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MENU_STATE=enabled:$($menuState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($menuState.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($menuState.IsKeyboardFocusable.ToString().ToLowerInvariant())"
  )
  [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_TREE=$($treeParts -join '>')")
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_MENU_PATTERNS=expand-collapse:$($hasExpandPattern.ToString().ToLowerInvariant());invoke:$($hasInvokePattern.ToString().ToLowerInvariant())"
  )
  if ($menuState.IsKeyboardFocusable) {
    try {
      $filterMenu.SetFocus()
      [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=returned")
    } catch {
      $focusError = $_.Exception.GetType().Name
      if ($focusError -notin @(
          "ElementNotEnabledException",
          "ElementNotAvailableException",
          "InvalidOperationException",
          "COMException",
          "NoClickablePointException"
        )) {
        $focusError = "Other"
      }
      [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=failed-$focusError")
      throw
    }
  } else {
    [Console]::Out.WriteLine("PROC_MON_FILTER_MENU_FOCUS=skipped-not-keyboard-focusable")
  }
  Set-Stage "expand-filter-menu"
  if ($hasExpandPattern) {
    $expandPattern.Expand()
  } elseif ($hasInvokePattern) {
    $invokePattern.Invoke()
  } else {
    throw "Process Monitor Filter menu exposes no supported open pattern"
  }
  Set-Stage "observe-menu-focus"
  $focusSnapshot = @{}
  Write-FocusObservation "after-open" $focusSnapshot
  Set-Stage "verify-menu-focus-snapshot"
  Write-FocusSnapshotObservation "caller" $focusSnapshot
  Set-Stage "resolve-open-filter-menu"
  if ($null -eq $focusSnapshot["Element"]) {
    throw "Process Monitor did not expose its focused menu element"
  }
  $menu = $focusSnapshot["Element"]
  $menuType = $focusSnapshot["ControlType"]
  if ($menuType -ne "ControlType.Menu") {
    Set-Stage "walk-to-open-filter-menu"
    $treeWalker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    for ($level = 0; $null -ne $menu -and $level -lt 4; $level++) {
      $menu = $treeWalker.GetParent($menu)
      if ($null -eq $menu) { break }
      $menuType = $menu.Current.ControlType.ProgrammaticName
      if ($menuType -eq "ControlType.Menu") { break }
    }
  }
  if ($null -eq $menu -or $menuType -ne "ControlType.Menu") {
    throw "Process Monitor did not expose its open Filter menu"
  }
  if ($focusSnapshot["ControlType"] -ne "ControlType.Menu") {
    Write-MenuItemsObservation "after-open" $menu
  }
  Set-Stage "enumerate-filter-menu-items"
  $menuItems = $menu.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $menuItemCount = [Math]::Min($menuItems.Count, 9999)
  $filterCommands = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  foreach ($item in $menuItems) {
    Set-Stage "read-filter-menu-item"
    $itemState = $item.Current
    Set-Stage "match-filter-menu-item"
    if ($itemState.Name -eq "Filter..." -and
      $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
      $filterCommands.Add($item)
    }
  }
  Set-Stage "verify-filter-command-count"
  $filterMatchCount = [Math]::Min($filterCommands.Count, 9999)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_COMMAND_MATCH=items:$menuItemCount;matches:$filterMatchCount"
  )
  if ($filterCommands.Count -ne 1) {
    throw "Process Monitor open menu did not expose one Filter command"
  }
  $filterCommand = $filterCommands[0]
  Set-Stage "read-filter-command-state"
  $filterCommandState = $filterCommand.Current
  Set-Stage "probe-filter-command-patterns"
  $filterInvokePattern = $null
  $hasFilterInvokePattern = $filterCommand.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [ref]$filterInvokePattern
  )
  $filterSelectionPattern = $null
  $hasFilterSelectionPattern = $filterCommand.TryGetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern,
    [ref]$filterSelectionPattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_COMMAND_PATTERNS=invoke:$($hasFilterInvokePattern.ToString().ToLowerInvariant());selection-item:$($hasFilterSelectionPattern.ToString().ToLowerInvariant())"
  )
  Set-Stage "validate-filter-command-state"
  if (-not $filterCommandState.IsEnabled -or
    $filterCommandState.IsOffscreen -or
    -not $filterCommandState.IsKeyboardFocusable -or
    -not $hasFilterInvokePattern) {
    throw "Process Monitor Filter command is not available through its InvokePattern"
  }
  Set-Stage "focus-filter-command"
  $filterCommand.SetFocus()
  Set-Stage "observe-filter-command-focus"
  Write-FocusObservation "filter-command" | Out-Null
  [Console]::Out.WriteLine("PROC_MON_FILTER_COMMAND_ACTIVATION=invoke-pattern")
  Set-Stage "invoke-filter-command"
  $filterInvokePattern.Invoke()
  Set-Stage "observe-dialog-focus"
  Write-FocusObservation "after-command-invoke" | Out-Null
  Write-FocusOwnerObservation "after-command-invoke" $process $main
  Set-Stage "wait-filter-dialog"
  $filterDialog = Wait-FilterDialog $process $main
  Set-Stage "reset-existing-filters"
  $reset = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "Reset"
  )) 5
  $reset.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
  Set-Stage "set-canary-filter"
  Set-FilterRule $filterDialog $CanaryPath
  Set-Stage "set-control-filter"
  Set-FilterRule $filterDialog $ControlPath
  Set-Stage "apply-filters"
  $ok = Wait-Element $filterDialog ([System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::NameProperty, "OK"
  )) 5
  $ok.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()

  Set-Stage "focus-main-for-drop-filtered-events"
  $main.SetFocus()
  Set-Stage "find-filter-menu-for-drop-filtered-events"
  $filterMenu = Wait-Element $main ([System.Windows.Automation.AndCondition]::new(
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::NameProperty, "Filter"
    ),
    [System.Windows.Automation.PropertyCondition]::new(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::MenuItem
    )
  )) 5
  $dropMenuPattern = $null
  if (-not $filterMenu.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$dropMenuPattern
    )) {
    throw "Process Monitor Filter menu does not expose InvokePattern"
  }
  Set-Stage "open-drop-filtered-events-menu"
  $dropMenuPattern.Invoke()
  Set-Stage "resolve-drop-filtered-events-menu"
  $dropMenu = $null
  $dropMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
        $dropMenu = $focused
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -ne $dropMenu) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $dropMenuDeadline)
  if ($null -eq $dropMenu) {
    throw "Process Monitor did not expose the opened Filter menu"
  }
  $dropMenuState = $dropMenu.Current
  $dropMenuOwned = ($dropMenuState.ProcessId -eq $process.Id)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_MENU_STATE=owner-same-process:$($dropMenuOwned.ToString().ToLowerInvariant());enabled:$($dropMenuState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dropMenuState.IsOffscreen.ToString().ToLowerInvariant())"
  )
  if (-not $dropMenuOwned -or -not $dropMenuState.IsEnabled -or $dropMenuState.IsOffscreen) {
    throw "Process Monitor Filter menu is not available in its own process"
  }
  Set-Stage "enumerate-drop-filtered-events-items"
  $dropItems = $dropMenu.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $dropMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  foreach ($item in $dropItems) {
    $itemState = $item.Current
    if ($itemState.Name -eq "Drop Filtered Events" -and
      $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
      $dropMatches.Add($item)
    }
  }
  $dropItemCount = [Math]::Min($dropItems.Count, 9999)
  $dropMatchCount = [Math]::Min($dropMatches.Count, 9999)
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_MENU_MATCH=items:$dropItemCount;matches:$dropMatchCount"
  )
  if ($dropMatches.Count -ne 1) {
    throw "Process Monitor open Filter menu did not expose one Drop Filtered Events item"
  }
  Set-Stage "find-drop-filtered-events"
  $drop = $dropMatches[0]
  $dropState = $drop.Current
  $togglePattern = $null
  Set-Stage "probe-drop-toggle-pattern"
  $hasTogglePattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.TogglePattern]::Pattern,
    [ref]$togglePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=toggle:$($hasTogglePattern.ToString().ToLowerInvariant())"
  )
  $invokePattern = $null
  Set-Stage "probe-drop-invoke-pattern"
  $hasInvokePattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.InvokePattern]::Pattern,
    [ref]$invokePattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=invoke:$($hasInvokePattern.ToString().ToLowerInvariant())"
  )
  $selectionItemPattern = $null
  Set-Stage "probe-drop-selection-item-pattern"
  $hasSelectionItemPattern = $drop.TryGetCurrentPattern(
    [System.Windows.Automation.SelectionItemPattern]::Pattern,
    [ref]$selectionItemPattern
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_PATTERN=selection-item:$($hasSelectionItemPattern.ToString().ToLowerInvariant())"
  )
  Set-Stage "probe-drop-item-state"
  $dropItemStatus = switch ($dropState.ItemStatus) {
    "Checked" { "checked" }
    "Unchecked" { "unchecked" }
    "On" { "on" }
    "Off" { "off" }
    "Mixed" { "mixed" }
    default { "other" }
  }
  $dropHelpText = switch ($dropState.HelpText) {
    "Checked" { "checked" }
    "Unchecked" { "unchecked" }
    "On" { "on" }
    "Off" { "off" }
    "Mixed" { "mixed" }
    default { "other" }
  }
  $dropFramework = switch ($dropState.FrameworkId) {
    "Win32" { "Win32" }
    "WPF" { "WPF" }
    "WinForm" { "WinForm" }
    "DirectUI" { "DirectUI" }
    default { "other" }
  }
  $dropNativeHandle = ($dropState.NativeWindowHandle -ne 0).ToString().ToLowerInvariant()
  $menuNativeHandle = (
    $dropMenu.Current.NativeWindowHandle -ne 0
  ).ToString().ToLowerInvariant()
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_ITEM_STATE=enabled:$($dropState.IsEnabled.ToString().ToLowerInvariant());offscreen:$($dropState.IsOffscreen.ToString().ToLowerInvariant());keyboard-focusable:$($dropState.IsKeyboardFocusable.ToString().ToLowerInvariant());item-status:$dropItemStatus;help-text:$dropHelpText"
  )
  [Console]::Out.WriteLine(
    "PROC_MON_FILTER_DROP_ITEM_BACKEND=framework:$dropFramework;native-window-handle:$dropNativeHandle;menu-window-handle:$menuNativeHandle"
  )
  Set-Stage "probe-drop-native-menu-state"
  $mainWindowHandle = [System.IntPtr]$main.Current.NativeWindowHandle
  $dropMenuWindowHandle = [System.IntPtr]$dropMenu.Current.NativeWindowHandle
  $nativeDropMenuSnapshot = Get-NativeDropMenuSnapshot $mainWindowHandle $dropMenuWindowHandle $process.Id
  Write-NativeDropMenuSnapshot $nativeDropMenuSnapshot "before"
  $accessibleDropMenuSnapshot = $null
  if ($nativeDropMenuSnapshot.CheckState -eq "unavailable") {
    $accessibleDropMenuSnapshot = Get-AccessibleDropMenuSnapshot `
      $dropMenuWindowHandle $process.Id "before"
  }
  $dropCheckState = Get-VerifiedDropMenuCheckState `
    $nativeDropMenuSnapshot $accessibleDropMenuSnapshot
  Set-Stage "verify-drop-native-menu-state"
  if ($dropCheckState -eq "unavailable") {
    throw "Process Monitor native menu state could not be verified"
  }
  if (-not $dropState.IsEnabled -or $dropState.IsOffscreen) {
    throw "Process Monitor Drop Filtered Events is unavailable"
  }
  if ($dropCheckState -eq "off") {
    if (-not $hasInvokePattern) {
      throw "Process Monitor Drop Filtered Events cannot be enabled without InvokePattern"
    }
    Set-Stage "invoke-drop-filtered-events"
    $invokePattern.Invoke()
    Start-Sleep -Milliseconds 100

    Set-Stage "reopen-drop-filtered-events-menu"
    $filterMenu = Wait-Element $main $filterMenuCondition 5
    $reopenMenuPattern = $null
    if (-not $filterMenu.TryGetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern,
        [ref]$reopenMenuPattern
      )) {
      throw "Process Monitor Filter menu does not expose InvokePattern after toggle"
    }
    $reopenMenuPattern.Invoke()

    Set-Stage "resolve-drop-filtered-events-menu-after-invoke"
    $dropMenu = $null
    $dropMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
      $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
      for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
        if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
          $dropMenu = $focused
          break
        }
        $focused = $treeWalker.GetParent($focused)
      }
      if ($null -ne $dropMenu) { break }
      Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $dropMenuDeadline)
    if ($null -eq $dropMenu) {
      throw "Process Monitor did not expose the reopened Filter menu"
    }
    $dropMenuState = $dropMenu.Current
    if ($dropMenuState.ProcessId -ne $process.Id -or
      -not $dropMenuState.IsEnabled -or
      $dropMenuState.IsOffscreen) {
      throw "Process Monitor reopened Filter menu is not available in its own process"
    }

    Set-Stage "enumerate-drop-filtered-events-items-after-invoke"
    $dropItems = $dropMenu.FindAll(
      [System.Windows.Automation.TreeScope]::Descendants,
      [System.Windows.Automation.Condition]::TrueCondition
    )
    $dropMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
    foreach ($item in $dropItems) {
      $itemState = $item.Current
      if ($itemState.Name -eq "Drop Filtered Events" -and
        $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
        $dropMatches.Add($item)
      }
    }
    if ($dropMatches.Count -ne 1) {
      throw "Process Monitor reopened Filter menu did not expose one Drop Filtered Events item"
    }
    $drop = $dropMatches[0]
    $dropState = $drop.Current
    if (-not $dropState.IsEnabled -or $dropState.IsOffscreen) {
      throw "Process Monitor reopened Drop Filtered Events item is unavailable"
    }

    $dropMenuWindowHandle = [System.IntPtr]$dropMenu.Current.NativeWindowHandle
    Set-Stage "verify-drop-native-menu-state"
    $nativeDropMenuSnapshot = Get-NativeDropMenuSnapshot `
      $mainWindowHandle $dropMenuWindowHandle $process.Id
    Write-NativeDropMenuSnapshot $nativeDropMenuSnapshot "after-invoke"
    $accessibleDropMenuSnapshot = $null
    if ($nativeDropMenuSnapshot.CheckState -eq "unavailable") {
      $accessibleDropMenuSnapshot = Get-AccessibleDropMenuSnapshot `
        $dropMenuWindowHandle $process.Id "after-invoke"
    }
    $dropCheckState = Get-VerifiedDropMenuCheckState `
      $nativeDropMenuSnapshot $accessibleDropMenuSnapshot
    if ($dropCheckState -ne "on") {
      throw "Process Monitor did not enable Drop Filtered Events"
    }
  }
  Set-Stage "drop-filtered-events-verified"

  Set-Stage "save-filter"
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
  $main.SetFocus()
  Set-Stage "open-file-menu-for-export"
  [System.Windows.Forms.SendKeys]::SendWait("%f")
  Set-Stage "resolve-file-menu-for-export"
  $saveMenu = $null
  $saveMenuDeadline = [DateTime]::UtcNow.AddSeconds(5)
  do {
    $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
    for ($level = 0; $null -ne $focused -and $level -lt 5; $level++) {
      if ($focused.Current.ControlType -eq [System.Windows.Automation.ControlType]::Menu) {
        $saveMenu = $focused
        break
      }
      $focused = $treeWalker.GetParent($focused)
    }
    if ($null -ne $saveMenu) { break }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $saveMenuDeadline)
  if ($null -eq $saveMenu) {
    throw "Process Monitor did not expose its File menu for configuration export"
  }
  $saveMenuState = $saveMenu.Current
  if ($saveMenuState.ProcessId -ne $process.Id -or
    -not $saveMenuState.IsEnabled -or
    $saveMenuState.IsOffscreen) {
    throw "Process Monitor File menu is not available for export in its own process"
  }
  Write-MenuItemsObservation "before-save" $saveMenu
  Set-Stage "find-export-config-command"
  $saveCommands = $saveMenu.FindAll(
    [System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition
  )
  $saveMatches = [System.Collections.Generic.List[System.Windows.Automation.AutomationElement]]::new()
  foreach ($item in $saveCommands) {
    $itemState = $item.Current
    if ($itemState.Name -eq "Export Configuration..." -and
      $itemState.ControlType.ProgrammaticName -eq "ControlType.MenuItem") {
      $saveMatches.Add($item)
    }
  }
  if ($saveMatches.Count -ne 1) {
    throw "Process Monitor File menu did not expose one Export Configuration command"
  }
  $saveFilter = $saveMatches[0]
  $saveFilterState = $saveFilter.Current
  if ($saveFilterState.ProcessId -ne $process.Id -or
    -not $saveFilterState.IsEnabled -or $saveFilterState.IsOffscreen) {
    throw "Process Monitor Export Configuration command is unavailable"
  }
  Set-Stage "probe-export-config-command"
  $saveInvokePattern = $null
  if (-not $saveFilter.TryGetCurrentPattern(
      [System.Windows.Automation.InvokePattern]::Pattern,
      [ref]$saveInvokePattern
    )) {
    throw "Process Monitor Export Configuration command does not expose InvokePattern"
  }
  Set-Stage "invoke-export-config-command"
  $saveInvokePattern.Invoke()
  Set-Stage "wait-export-config-dialog"
  $saveControls = Wait-ConfigSaveDialog $process $main
  $fileName = $saveControls.FileName
  $save = $saveControls.Save
  if ($fileName.Current.ProcessId -ne $process.Id -or
    $save.Current.ProcessId -ne $process.Id -or
    -not $fileName.Current.IsEnabled -or $fileName.Current.IsOffscreen -or
    -not $save.Current.IsEnabled -or $save.Current.IsOffscreen) {
    throw "Process Monitor configuration save controls are unavailable"
  }
  Set-Stage "set-export-config-path"
  $fileNamePattern = $fileName.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
  if ($fileNamePattern.Current.IsReadOnly) {
    throw "Process Monitor configuration file name is read-only"
  }
  $fileNamePattern.SetValue($ConfigPath)
  Set-Stage "focus-export-config-save"
  if (-not $save.Current.IsKeyboardFocusable) {
    throw "Process Monitor configuration Save button cannot receive focus"
  }
  $save.SetFocus()
  Set-Stage "verify-export-config-path"
  $saveFocusState = Wait-ConfigSaveFocus $save
  $saveFocusGate = if (
    $null -ne $saveFocusState -and
    $saveFocusState.ProcessId -eq $process.Id -and
    $saveFocusState.IsEnabled -and
    -not $saveFocusState.IsOffscreen -and
    $saveFocusState.IsKeyboardFocusable -and
    $saveFocusState.HasKeyboardFocus
  ) { "passed" } else { "failed" }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FOCUS=gate:$saveFocusGate")
  if ($saveFocusGate -ne "passed") {
    Write-ConfigSaveObservation "focus-failed" $saveControls $process.Id $ConfigPath
    throw "Process Monitor configuration Save button did not receive keyboard focus"
  }
  if ($fileNamePattern.Current.Value -cne $ConfigPath) {
    throw "Process Monitor configuration file name did not retain the requested path"
  }
  Set-Stage "activate-export-config-dialog"
  $dialogHandle = [IntPtr]$saveControls.Dialog.Current.NativeWindowHandle
  $foregroundGate = "failed"
  if (
    $dialogHandle -ne [IntPtr]::Zero -and
    [ProcmonNativeMenu]::GetWindowProcessId($dialogHandle) -eq $process.Id
  ) {
    [ProcmonNativeMenu]::SetForegroundWindow($dialogHandle) | Out-Null
    $foregroundDeadline = [DateTime]::UtcNow.AddSeconds(2)
    do {
      $foregroundHandle = [ProcmonNativeMenu]::GetForegroundWindow()
      if (
        $foregroundHandle -eq $dialogHandle -and
        [ProcmonNativeMenu]::GetWindowProcessId($foregroundHandle) -eq $process.Id
      ) {
        $foregroundGate = "passed"
        break
      }
      Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $foregroundDeadline)
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_SAVE_FOREGROUND=gate:$foregroundGate")
  if ($foregroundGate -ne "passed") {
    Write-ConfigSaveObservation "foreground-failed" $saveControls $process.Id $ConfigPath
    throw "Process Monitor configuration save dialog did not become the foreground window"
  }
  Write-ConfigOutputObservation "before-save" $ConfigPath
  Set-Stage "confirm-export-config-enter"
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  Write-FocusObservation "after-invoke"
  Write-FocusOwnerObservation "after-save-enter" $process $main
  Write-ConfigSaveObservation "after-invoke" $saveControls $process.Id $ConfigPath
  Write-ConfigOutputObservation "after-invoke" $ConfigPath
  Set-Stage "verify-filter-file"
  try {
    Wait-FilterConfigFile $ConfigPath
  } catch {
    Write-ConfigSaveObservation "verify-failed" $saveControls $process.Id $ConfigPath
    Write-ConfigOutputObservation "after-wait" $ConfigPath
    throw
  }
  Write-ConfigOutputObservation "after-wait" $ConfigPath
} catch {
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILED_STAGE=$stage")
  $failureException = $_.Exception
  if (
    $failureException.GetType().Name -eq "MethodInvocationException" -and
    $null -ne $failureException.InnerException
  ) {
    $failureException = $failureException.InnerException
  }
  $failureType = $failureException.GetType().Name
  if ($failureType -notin @(
      "AmbiguousMatchException",
      "ArgumentException",
      "DllNotFoundException",
      "EntryPointNotFoundException",
      "COMException",
      "ElementNotAvailableException",
      "InvalidOperationException",
      "MethodAccessException",
      "MethodException",
      "MethodInvocationException",
      "MissingMethodException",
      "NullReferenceException",
      "RuntimeException",
      "TargetInvocationException",
      "TypeInitializationException"
    )) {
    $failureType = "Other"
  }
  [Console]::Out.WriteLine("PROC_MON_FILTER_FAILURE=$failureType")
  exit 1
} finally {
  if (-not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(5000)) {
      Stop-Process -Id $process.Id -Force
    }
  }
}
