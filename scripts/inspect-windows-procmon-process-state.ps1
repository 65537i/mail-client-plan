param(
  [Parameter(Mandatory = $true)][string]$ProcmonPath,
  [Parameter(Mandatory = $true)]
  [ValidateSet("before-filter-setup", "after-filter-setup", "after-capture-stop", "after-csv-export")]
  [string]$Stage
)

$ErrorActionPreference = "Stop"
$expectedPath = [IO.Path]::GetFullPath($ProcmonPath)
$namedProcesses = @(
  Get-CimInstance -ClassName Win32_Process `
    -Filter "(Name = 'Procmon.exe' OR Name = 'Procmon64.exe' OR Name = 'Procmon64a.exe')" `
    -ErrorAction Stop
)
$instances = 0
$pathUnavailable = 0

foreach ($candidate in $namedProcesses) {
  if ([string]::IsNullOrWhiteSpace($candidate.ExecutablePath)) {
    $pathUnavailable = $pathUnavailable + 1
    continue
  }
  $candidatePath = [IO.Path]::GetFullPath($candidate.ExecutablePath)
  if ([string]::Equals(
      $candidatePath,
      $expectedPath,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    $instances = $instances + 1
  }
}

if ($namedProcesses.Count -gt 999 -or $instances -gt 999 -or $pathUnavailable -gt 999) {
  throw "Process Monitor process state exceeded the diagnostic limit"
}

[Console]::Out.WriteLine(
  "PROC_MON_PROCESS_STATE=stage:$Stage;named:$($namedProcesses.Count);instances:$instances;path-unavailable:$pathUnavailable"
)
