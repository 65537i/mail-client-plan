param(
  [Parameter(Mandatory = $true)][int]$OwnerProcessId,
  [string]$TargetPath,
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

function Get-ProcmonRegistryEvidence {
  param([Microsoft.Win32.RegistryKey]$ServicesRoot)
  $serviceNames = $ServicesRoot.GetSubKeyNames()
  if ($serviceNames.Count -gt 4096) {
    throw "System driver registry inventory exceeded its limit"
  }
  $candidates = @($serviceNames | Where-Object { $_ -match '(?i)procmon' })
  if ($candidates.Count -gt 64) {
    throw "Procmon registry candidate inventory exceeded its limit"
  }
  $imageCandidates = 0
  $imageValueEntries = 0
  $imageValues = 0
  $imagePathsPresent = 0
  $standardNameCandidates = 0
  $typeValues = 0
  $startValues = 0
  $parametersKeys = 0
  $candidateNames = [System.Collections.Generic.List[string]]::new()
  foreach ($candidate in $candidates) {
    if ($candidate -match '^PROCMON[0-9]*$') { $standardNameCandidates++ }
    $candidateNames.Add($candidate)
    $key = $ServicesRoot.OpenSubKey($candidate, $false)
    if ($null -eq $key) {
      throw "Procmon registry candidate disappeared during inspection"
    }
    try {
      $valueNames = $key.GetValueNames()
      $subKeyNames = $key.GetSubKeyNames()
      if ($valueNames.Count -gt 128 -or $subKeyNames.Count -gt 128) {
        throw "Procmon registry candidate exceeded its metadata limit"
      }
      if ($valueNames -ccontains "ImagePath") { $imageValueEntries++ }
      if ($valueNames -ccontains "Type") { $typeValues++ }
      if ($valueNames -ccontains "Start") { $startValues++ }
      if ($subKeyNames -ccontains "Parameters") { $parametersKeys++ }
      $imagePath = $key.GetValue(
        "ImagePath", $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
      )
      if ($null -eq $imagePath) { continue }
      if ($imagePath -isnot [string] -or $imagePath.Length -gt 2048) {
        throw "Procmon registry image path has an unsupported shape"
      }
      $imageCandidates++
      $imageValues++
      $expandedPath = [Environment]::ExpandEnvironmentVariables($imagePath.Trim('"'))
      if ([IO.Path]::IsPathRooted($expandedPath) -and
        [IO.File]::Exists($expandedPath)) {
        $imagePathsPresent++
      }
    } finally {
      $key.Dispose()
    }
  }
  $otherCandidates = $candidates.Count - $standardNameCandidates
  return [pscustomobject]@{
    Evidence = "keys:$($serviceNames.Count);candidates:$($candidates.Count);standard-name-candidates:$standardNameCandidates;other-candidates:$otherCandidates;image-value-entries:$imageValueEntries;image-candidates:$imageCandidates;image-values:$imageValues;image-paths-present:$imagePathsPresent;type-values:$typeValues;start-values:$startValues;parameters-keys:$parametersKeys"
    Names = $candidateNames.ToArray()
  }
}

function Get-ProcmonServiceStatusEvidence {
  param([string[]]$Names)
  if ($Names.Count -gt 64) {
    throw "Procmon service status query exceeded its limit"
  }
  $found = 0
  $notFound = 0
  $running = 0
  $stopped = 0
  $otherStates = 0
  foreach ($name in $Names) {
    if ($name -notmatch '(?i)procmon' -or $name.Length -gt 256) {
      throw "Procmon service status query has an unsupported name"
    }
    try {
      $service = Get-Service -Name $name -ErrorAction Stop
    } catch {
      if ($_.FullyQualifiedErrorId -notlike "NoServiceFoundForGivenName,*") {
        throw
      }
      $notFound++
      continue
    }
    if ($null -eq $service -or $service.Status -isnot [System.ServiceProcess.ServiceControllerStatus]) {
      throw "Procmon service controller returned an unsupported status"
    }
    $found++
    if ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
      $running++
    } elseif ($service.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
      $stopped++
    } else {
      $otherStates++
    }
  }
  return "candidates:$($Names.Count);found:$found;not-found:$notFound;running:$running;stopped:$stopped;other-states:$otherStates"
}

function Get-ProcmonFilterManagerEvidence {
  param([string[]]$Lines)
  if ($Lines.Count -gt 256) {
    throw "Filter Manager inventory exceeded its limit"
  }
  $candidates = 0
  $instances = 0
  foreach ($line in $Lines) {
    if ($line -isnot [string] -or $line.Length -gt 512) {
      throw "Filter Manager inventory has an unsupported shape"
    }
    if ($line -notmatch '^\s*(?i:PROCMON)') { continue }
    $match = [regex]::Match(
      $line,
      '^\s*(?i:PROCMON[0-9]*)\s+([0-9]{1,3})\s+[0-9]{1,12}(?:\.[0-9]{1,4})?\s+[0-9]{1,3}\s*$'
    )
    if (-not $match.Success) {
      throw "Procmon Filter Manager candidate has an unsupported shape"
    }
    $instanceCount = 0
    if (-not [int]::TryParse(
        $match.Groups[1].Value,
        [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$instanceCount
      )) {
      throw "Procmon Filter Manager instance count is invalid"
    }
    $candidates++
    $instances += $instanceCount
    if ($candidates -gt 64 -or $instances -gt 63936) {
      throw "Procmon Filter Manager candidate inventory exceeded its limit"
    }
  }
  return "candidates:$candidates;instances:$instances"
}

function Get-ProcmonFilterManagerVolumeEvidence {
  param([string[]]$Lines, [string]$ExpectedVolume)
  $script:filterManagerVolumeParseState = "started"
  if ($Lines.Count -eq 0 -or $Lines.Count -gt 256) {
    $script:filterManagerVolumeParseState = if ($Lines.Count -eq 0) { "empty-output" } else { "line-limit" }
    throw "Filter Manager volume inventory exceeded its limit"
  }
  $headerSeen = $false
  $separatorSeen = $false
  $volumeHeadingSeen = $false
  $hasSupportedFeatures = $false
  $candidates = 0
  $instances = 0
  foreach ($line in $Lines) {
    if ($line -isnot [string] -or $line.Length -gt 512) {
      $script:filterManagerVolumeParseState = "line-shape"
      throw "Filter Manager volume inventory has an unsupported shape"
    }
    if ($line -match '^\s*Filter Name\s+Num Instances\s+Altitude\s+Frame(?:\s+SprtFtrs)?\s*$') {
      if ($headerSeen) {
        $script:filterManagerVolumeParseState = "duplicate-header"
        throw "Filter Manager volume inventory repeated its header"
      }
      $headerSeen = $true
      $hasSupportedFeatures = $line -match '\sSprtFtrs\s*$'
      continue
    }
    if (-not $headerSeen) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      if ($line -match '^\s*Instances for\s+(.+?)\s*$') {
        $reportedVolume = $Matches[1].Trim()
        $expectedVolumeMatches = $false
        if ($ExpectedVolume -is [string] -and $ExpectedVolume.Length -gt 0 -and
          $ExpectedVolume.Length -le 260) {
          $expectedHeadings = @($ExpectedVolume, "$ExpectedVolume\")
          foreach ($expectedHeading in $expectedHeadings) {
            if ([string]::Equals(
                $reportedVolume,
                $expectedHeading,
                [System.StringComparison]::OrdinalIgnoreCase
              )) {
              $expectedVolumeMatches = $true
              break
            }
          }
        }
        if ($expectedVolumeMatches -and -not $volumeHeadingSeen) {
          $volumeHeadingSeen = $true
          continue
        }
        $script:filterManagerVolumeParseState = if ($reportedVolume -match '^[A-Za-z]:') {
          $driveRemainder = $reportedVolume.Substring(2)
          if ($driveRemainder -match '^[\\/]') {
            "volume-heading-drive-path"
          } elseif ($driveRemainder -match '^\s') {
            $driveDecoration = $driveRemainder.TrimStart()
            if ($driveDecoration.StartsWith("(")) {
              "volume-heading-drive-decorated-parenthesis"
            } elseif ($driveDecoration.StartsWith("[")) {
              "volume-heading-drive-decorated-bracket"
            } elseif ($driveDecoration.StartsWith("'") -or $driveDecoration.StartsWith('"')) {
              "volume-heading-drive-decorated-quoted"
            } elseif ($driveDecoration.Substring(0, 1) -match '^[A-Za-z]') {
              "volume-heading-drive-decorated-text"
            } elseif ($driveDecoration.Substring(0, 1) -match '^[0-9]') {
              "volume-heading-drive-decorated-numeric"
            } elseif ($driveDecoration.StartsWith("\") -or $driveDecoration.StartsWith("/")) {
              "volume-heading-drive-decorated-path"
            } elseif ($driveDecoration.Substring(0, 1) -match '^[:;,.]$') {
              "volume-heading-drive-decorated-punctuation"
            } else {
              "volume-heading-drive-decorated-other"
            }
          } else {
            "volume-heading-drive-other"
          }
        } elseif ($reportedVolume -match '^\\\\\?\\Volume\{') {
          "volume-heading-guid-prefix"
        } elseif ($reportedVolume -match '^\\Device\\') {
          "volume-heading-device-prefix"
        } elseif ($reportedVolume -match '^\\\?\?\\') {
          "volume-heading-object-manager-prefix"
        } elseif ($reportedVolume -match '^[\\/]') {
          "volume-heading-rooted"
        } else {
          "volume-heading-other"
        }
        throw "Filter Manager volume heading did not match the target"
      }
      if ($line -match '^\s*Instance Name\s+Altitude\s+Frame\s+Volume Name\s*$') {
        $script:filterManagerVolumeParseState = "instance-list-header"
      } elseif ($line -match '^\s*Instances for volume\b') {
        $script:filterManagerVolumeParseState = "volume-heading"
      } elseif ($line -match '^\s*Instances for\b') {
        $script:filterManagerVolumeParseState = "instances-heading"
      } elseif ($line -match '^\s*Instances\b') {
        $script:filterManagerVolumeParseState = "instances-heading"
      } elseif ($line -match '^\s*Instance\b') {
        $script:filterManagerVolumeParseState = "instance-heading"
      } elseif ($line -match '^\s*Filter Manager\b') {
        $script:filterManagerVolumeParseState = "filter-manager-heading"
      } elseif ($line -match '^\s*Filter\b') {
        $script:filterManagerVolumeParseState = "filter-heading"
      } elseif ($line -match '^\s*Volume\b') {
        $script:filterManagerVolumeParseState = "volume-heading"
      } else {
        $script:filterManagerVolumeParseState = "unexpected-preamble"
      }
      throw "Filter Manager volume inventory omitted its expected header"
    }
    if (-not $separatorSeen) {
      $separatorPattern = if ($hasSupportedFeatures) {
        '^\s*-{3,}\s+-{3,}\s+-{3,}\s+-{3,}\s+-{3,}\s*$'
      } else {
        '^\s*-{3,}\s+-{3,}\s+-{3,}\s+-{3,}\s*$'
      }
      if ($line -notmatch $separatorPattern) {
        $script:filterManagerVolumeParseState = "separator-shape"
        throw "Filter Manager volume inventory omitted its expected separator"
      }
      $separatorSeen = $true
      continue
    }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $featureColumn = if ($hasSupportedFeatures) { '\s+(0x[0-9A-Fa-f]{1,8})' } else { '' }
    $match = [regex]::Match(
      $line,
      '^\s*(\S{1,256})\s+([0-9]{1,3})\s+[0-9]{1,12}(?:\.[0-9]{1,4})?\s+[0-9]{1,3}' +
        $featureColumn + '\s*$'
    )
    if (-not $match.Success) {
      $script:filterManagerVolumeParseState = "row-shape"
      throw "Filter Manager volume inventory returned an unsupported row"
    }
    if ($match.Groups[1].Value -notmatch '^(?i:PROCMON[0-9]*)$') { continue }
    $instanceCount = 0
    if (-not [int]::TryParse(
        $match.Groups[2].Value,
        [System.Globalization.NumberStyles]::None,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$instanceCount
      )) {
      $script:filterManagerVolumeParseState = "invalid-count"
      throw "Filter Manager volume instance count is invalid"
    }
    if ($instanceCount -gt 64) {
      $script:filterManagerVolumeParseState = "count-limit"
      throw "Filter Manager volume instance count exceeded its limit"
    }
    $candidates++
    $instances += $instanceCount
    if ($candidates -gt 64 -or $instances -gt 4096) {
      $script:filterManagerVolumeParseState = "inventory-limit"
      throw "Filter Manager volume candidate inventory exceeded its limit"
    }
  }
  if (-not $headerSeen -or -not $separatorSeen) {
    $script:filterManagerVolumeParseState = "incomplete-table"
    throw "Filter Manager volume inventory is incomplete"
  }
  $script:filterManagerVolumeParseState = "valid"
  return "candidates:$candidates;instances:$instances"
}

function Get-ProcmonFilterManagerSnapshot {
  param([string]$Path)
  $script:stage = "query-filter-manager-filter-inventory"
  $filterManagerPath = Join-Path $env:SystemRoot "System32\fltmc.exe"
  if (-not [IO.File]::Exists($filterManagerPath)) {
    throw "Filter Manager query utility is unavailable"
  }
  $lines = @(& $filterManagerPath filters 2>$null)
  if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) {
    throw "Filter Manager query failed"
  }
  $evidence = Get-ProcmonFilterManagerEvidence $lines
  $candidateNames = @(
    foreach ($line in $lines) {
      if ($line -match '^\s*(?i:PROCMON[0-9]*)\s+') {
        ([regex]::Match($line, '^\s*(PROCMON[0-9]*)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Groups[1].Value.ToUpperInvariant()
      }
    }
  )
  if ($candidateNames.Count -gt 64) {
    throw "Procmon Filter Manager candidate inventory exceeded its limit"
  }
  $script:stage = "resolve-filter-manager-target-volume"
  if ($Path -isnot [string] -or $Path.Length -eq 0 -or $Path.Length -gt 2048 -or
    -not [IO.Path]::IsPathRooted($Path) -or -not [IO.File]::Exists($Path)) {
    throw "Procmon target-volume path is unavailable"
  }
  $volumePath = [ProcmonCaptureWindows]::GetVolumePathName([IO.Path]::GetFullPath($Path))
  if ($volumePath -isnot [string] -or $volumePath.Length -gt 260 -or
    -not $volumePath.EndsWith("\")) {
    throw "Procmon target-volume mount point is unsupported"
  }
  $volumeName = $volumePath.TrimEnd('\')
  if ($volumeName.Length -eq 0 -or
    $volumeName -notmatch '^(?:[A-Za-z]:|[A-Za-z]:\\[A-Za-z0-9_.$ -]+(?:\\[A-Za-z0-9_.$ -]+)*)$') {
    throw "Procmon target-volume mount point has an unsupported shape"
  }
  $script:stage = "query-filter-manager-instance-command"
  $script:filterManagerInstanceQueryExitCode = $null
  $instanceLines = @(& $filterManagerPath instances -v $volumeName 2>$null)
  $script:filterManagerInstanceQueryExitCode = $LASTEXITCODE
  if ($script:filterManagerInstanceQueryExitCode -ne 0) {
    throw "Procmon target-volume instance query failed"
  }
  $script:stage = "parse-filter-manager-instance-output"
  $volumeEvidence = Get-ProcmonFilterManagerVolumeEvidence $instanceLines $volumeName
  $volumeEvidenceParts = $volumeEvidence -split ";", 2
  $targetVolumeCandidateCount = [int]($volumeEvidenceParts[0] -replace "^candidates:", "")
  $targetVolumeInstances = [int]($volumeEvidenceParts[1] -replace "^instances:", "")
  if ($targetVolumeCandidateCount -gt $candidateNames.Count -or
    $targetVolumeInstances -gt $targetVolumeCandidateCount * 64) {
    throw "Procmon target-volume instance inventory is inconsistent"
  }
  $attached = ($targetVolumeInstances -gt 0).ToString().ToLowerInvariant()
  return "$evidence;target-volume-attached:$attached;target-volume-instances:$targetVolumeInstances"
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumePathName(
        string fileName, StringBuilder volumePathName, uint bufferLength);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", ExactSpelling = true)]
    private static extern IntPtr ReadListCount(
        IntPtr window, uint message, UIntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out UIntPtr result);

    public static string GetVolumePathName(string path)
    {
        if (String.IsNullOrWhiteSpace(path) || path.Length > 2048)
            throw new InvalidOperationException("Target path is unsupported");
        var volumePath = new StringBuilder(261);
        if (!GetVolumePathName(path, volumePath, (uint)volumePath.Capacity))
            throw new InvalidOperationException("Target volume mount point is unavailable");
        return volumePath.ToString();
    }

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
  $stage = "query-driver-registry-inventory"
  $registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
    [Microsoft.Win32.RegistryHive]::LocalMachine,
    [Microsoft.Win32.RegistryView]::Registry64
  )
  try {
    $servicesRoot = $registryBase.OpenSubKey("SYSTEM\CurrentControlSet\Services", $false)
    if ($null -eq $servicesRoot) {
      throw "System driver registry inventory is unavailable"
    }
    try {
      $registryInventory = Get-ProcmonRegistryEvidence $servicesRoot
    } finally {
      $servicesRoot.Dispose()
    }
  } finally {
    $registryBase.Dispose()
  }
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_DRIVER_REGISTRY=$($registryInventory.Evidence)")
  $stage = "query-procmon-service-controller"
  $serviceEvidence = Get-ProcmonServiceStatusEvidence $registryInventory.Names
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_SERVICE_STATUS=$serviceEvidence")
  $stage = "query-filter-manager-inventory"
  $stage = "query-filter-manager-volume-instances"
  $filterManagerEvidence = Get-ProcmonFilterManagerSnapshot $TargetPath
  [Console]::Out.WriteLine("PROC_MON_CAPTURE_FILTER_MANAGER=$filterManagerEvidence")
  $stage = "inspect-capture-window"
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
  if ($null -ne $script:filterManagerInstanceQueryExitCode -and
    $script:filterManagerInstanceQueryExitCode -ne 0) {
    $queryExitCode = if ($script:filterManagerInstanceQueryExitCode -ge 0 -and
      $script:filterManagerInstanceQueryExitCode -le 255) {
      $script:filterManagerInstanceQueryExitCode.ToString(
        [System.Globalization.CultureInfo]::InvariantCulture
      )
    } else { "out-of-range" }
    [Console]::Out.WriteLine("PROC_MON_CAPTURE_FILTER_MANAGER_COMMAND=exit-code:$queryExitCode")
  }
  if ($stage -eq "parse-filter-manager-instance-output" -and
    $script:filterManagerVolumeParseState -in @(
      "started",
      "empty-output",
      "line-limit",
      "line-shape",
      "duplicate-header",
      "instance-list-header",
      "volume-heading",
      "volume-heading-drive-path",
      "volume-heading-drive-decorated-parenthesis",
      "volume-heading-drive-decorated-bracket",
      "volume-heading-drive-decorated-quoted",
      "volume-heading-drive-decorated-text",
      "volume-heading-drive-decorated-numeric",
      "volume-heading-drive-decorated-path",
      "volume-heading-drive-decorated-punctuation",
      "volume-heading-drive-decorated-other",
      "volume-heading-drive-other",
      "volume-heading-guid-prefix",
      "volume-heading-device-prefix",
      "volume-heading-object-manager-prefix",
      "volume-heading-rooted",
      "volume-heading-other",
      "instances-heading",
      "instance-heading",
      "filter-manager-heading",
      "filter-heading",
      "unexpected-preamble",
      "separator-shape",
      "row-shape",
      "invalid-count",
      "count-limit",
      "inventory-limit",
      "incomplete-table",
      "valid"
    )) {
    [Console]::Out.WriteLine(
      "PROC_MON_CAPTURE_FILTER_MANAGER_PARSE=$script:filterManagerVolumeParseState"
    )
  }
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
