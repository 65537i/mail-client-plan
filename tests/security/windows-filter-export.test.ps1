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
  [pscustomobject]@{ Heading = "Instances for D: metadata"; State = "volume-heading-drive-decorated-text" }
  [pscustomobject]@{ Heading = "Instances for D: Volume Name: value"; State = "volume-heading-drive-decorated-volume-name" }
  [pscustomobject]@{ Heading = "Instances for D: Volume GUID: value"; State = "volume-heading-drive-decorated-volume-guid" }
  [pscustomobject]@{ Heading = "Instances for D: Volume ID: value"; State = "volume-heading-drive-decorated-volume-id" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: \\?\Volume{fixture}"; State = "volume-heading-drive-decorated-volume-colon-guid" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: \Device\fixture"; State = "volume-heading-drive-decorated-volume-colon-device" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: \??\fixture"; State = "volume-heading-drive-decorated-volume-colon-object-manager" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: E:"; State = "volume-heading-drive-decorated-volume-colon-drive" }
  [pscustomobject]@{ Heading = "Instances for D: Volume:"; State = "volume-heading-drive-decorated-volume-colon-empty" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: metadata"; State = "volume-heading-drive-decorated-volume-colon-text" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: 12"; State = "volume-heading-drive-decorated-volume-colon-numeric" }
  [pscustomobject]@{ Heading = "Instances for D: Volume: @"; State = "volume-heading-drive-decorated-volume-colon-other" }
  [pscustomobject]@{ Heading = "Instances for D: Volume\value"; State = "volume-heading-drive-decorated-volume-path" }
  [pscustomobject]@{ Heading = "Instances for D: Volume metadata"; State = "volume-heading-drive-decorated-volume-other" }
  [pscustomobject]@{ Heading = "Instances for D: Device Name: value"; State = "volume-heading-drive-decorated-device" }
  [pscustomobject]@{ Heading = "Instances for D: Harddisk Volume"; State = "volume-heading-drive-decorated-harddisk" }
  [pscustomobject]@{ Heading = "Instances for D: 12"; State = "volume-heading-drive-decorated-numeric" }
  [pscustomobject]@{ Heading = "Instances for D: \metadata"; State = "volume-heading-drive-decorated-path" }
  [pscustomobject]@{ Heading = "Instances for D: :metadata"; State = "volume-heading-drive-decorated-punctuation" }
  [pscustomobject]@{ Heading = "Instances for D: @metadata"; State = "volume-heading-drive-decorated-other" }
)
foreach ($fixture in $decoratedDriveShapeFixtures) {
  $rejected = $false
  try { Get-ProcmonFilterManagerVolumeEvidence @($fixture.Heading) "C:" | Out-Null } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerVolumeParseState -cne $fixture.State) {
    throw "A drive heading decoration must remain rejected at $($fixture.State)"
  }
}
$headingTargetFixtures = @(
  [pscustomobject]@{ Expected = "C:\"; Target = "drive-root-mismatch" }
  [pscustomobject]@{ Expected = "D:\mount\"; Target = "mount-path" }
  [pscustomobject]@{ Expected = ""; Target = "missing" }
  [pscustomobject]@{ Expected = "\\?\Volume{fixture}\"; Target = "other" }
)
foreach ($fixture in $headingTargetFixtures) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @(
      "Instances for D: Volume:", $volumeHeader, $volumeSeparator
    ) $fixture.Expected | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or
    $script:filterManagerVolumeParseState -cne "volume-heading-drive-decorated-volume-colon-empty" -or
    $script:filterManagerHeadingTarget -cne $fixture.Target) {
    throw "Unsupported heading targets must remain rejected and safely classified"
  }
}
$supportedVolumeHeadings = @(
  [pscustomobject]@{ Heading = "Instances for D: Volume:"; Expected = "D:" }
  [pscustomobject]@{ Heading = "Instances for d: Volume:"; Expected = "D:\" }
  [pscustomobject]@{ Heading = "Instances for D: Volume:"; Expected = "d:\" }
  [pscustomobject]@{ Heading = "Instances for D:\"; Expected = "D:" }
)
foreach ($fixture in $supportedVolumeHeadings) {
  $evidence = Get-ProcmonFilterManagerVolumeEvidence @(
    $fixture.Heading, $volumeHeader, $volumeSeparator, "PROCMON24 2 385200 0 0x00"
  ) $fixture.Expected
  if ($evidence -cne "candidates:1;instances:2" -or
    $script:filterManagerVolumeParseState -cne "valid") {
    throw "Supported headings must retain exact target-volume instance evidence"
  }
}
$unsupportedVolumeHeadings = @(
  [pscustomobject]@{ Lines = @("Instances for C: Volume:") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume: metadata") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume: E:") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume: \Device\fixture") }
  [pscustomobject]@{ Lines = @("Instances for D:\nested Volume:") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume:", "Instances for D: Volume:") }
  [pscustomobject]@{ Lines = @("Instances for D:\", "Instances for D: Volume:") }
  [pscustomobject]@{ Lines = @("Instances for D: Volume:", "Instances for D:\") }
)
foreach ($fixture in $unsupportedVolumeHeadings) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence (
      $fixture.Lines + @($volumeHeader, $volumeSeparator, "PROCMON24 2 385200 0 0x00")
    ) "D:\" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected) {
    throw "Mismatched, extended and duplicate volume headings must remain rejected"
  }
}
Get-ProcmonFilterManagerVolumeEvidence @($volumeHeader, $volumeSeparator) "C:" | Out-Null
if ($script:filterManagerHeadingTarget -cne "unobserved") {
  throw "Heading target diagnostics must reset between queries"
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
$instanceHeader = "Filter Altitude Instance Name Frame SprtFtrs VlStatus"
$instanceSeparator = "-------- -------- -------- ----- -------- --------"
$instanceRows = @(
  "WdFilter 328010 unrelated 0 0x00 0"
  "PROCMON24 385200 first 0 0x03 0x00"
  "procmon24 385200.5 second 0 0x03 0"
  "PROCMON25 385201 third 1 0x01 0"
)
if ((Get-ProcmonFilterManagerVolumeEvidence (
      @("Instances for D: Volume:", $instanceHeader, $instanceSeparator) + $instanceRows
    ) "D:") -cne "candidates:2;instances:3") {
  throw "Instance rows must count distinct filters and individual instances separately"
}
if ((Get-ProcmonFilterManagerVolumeEvidence @(
      $instanceHeader, $instanceSeparator
    ) "D:") -cne "candidates:0;instances:0") {
  throw "An empty instance table must remain unattached"
}
$invalidInstanceTables = @(
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceHeader, $instanceSeparator) }
  [pscustomobject]@{ Lines = @($instanceHeader, $volumeSeparator) }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, "PROCMON24 385200 first 0 invalid 0") }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, "Unrelated invalid") }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, "PROCMON24 385200 first 0 0x03 private") }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, "PROCMON24 385200 first 0 0x03 0 extra") }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, "PROCMON24 385200 first 0 0x03 0", "procmon24 385200 FIRST 0 0x03 0") }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator, $volumeHeader) }
  [pscustomobject]@{ Lines = @($instanceHeader, $instanceSeparator) + @(1..65 | ForEach-Object { "PROCMON24 385200 instance$_ 0 0x03 0" }) }
)
foreach ($fixture in $invalidInstanceTables) {
  $rejected = $false
  try { Get-ProcmonFilterManagerVolumeEvidence $fixture.Lines "D:" | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Malformed or oversized instance tables must fail closed" }
}
$rowShapeFixtures = @(
  [pscustomobject]@{ Row = "PROCMON24 385200 private 0 0x03 unsupported"; Shape = "text-number-text-number-hex-text" }
  [pscustomobject]@{ Row = "Unrelated C:\private"; Shape = "text-text" }
  [pscustomobject]@{ Row = ("private " * 17); Shape = "token-limit" }
)
foreach ($fixture in $rowShapeFixtures) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $instanceSeparator, $fixture.Row) "D:" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerRowShape -cne $fixture.Shape) {
    throw "Unsupported row diagnostics must contain only bounded token classes"
  }
}
Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $instanceSeparator) "D:" | Out-Null
if ($script:filterManagerRowShape -cne "unobserved") { throw "Row diagnostics must reset" }
$columnSeparator = ("-" * 20) + " " + ("-" * 13) + " " + ("-" * 32) + " " +
  ("-" * 7) + " " + ("-" * 8) + " " + ("-" * 8)
$columnFixtures = @(
  [pscustomobject]@{ Values = @("Unrelated", "328010", "private instance", "0", "00000003", "private"); Shape = "word-integer-words-integer-digits8-word" }
  [pscustomobject]@{ Values = @("Unrelated", "328010.5", "private", "<Legacy>", "0000000f", "0x00"); Shape = "word-decimal-word-legacy-barehex-hex" }
  [pscustomobject]@{ Values = @("C:\private", "invalid", "private instance", "unknown", "0x03", "private"); Shape = "word-word-words-word-hex-word" }
  [pscustomobject]@{ Values = @("Unrelated", "", "", "", "", ""); Shape = "word-empty-empty-empty-empty-empty" }
)
foreach ($fixture in $columnFixtures) {
  $row = "{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f $fixture.Values
  foreach ($variant in @($row, $row.TrimEnd())) {
    $rejected = $false
    try {
      Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $columnSeparator, $variant) "D:" | Out-Null
    } catch { $rejected = $true }
    if (-not $rejected -or $script:filterManagerColumnShape -cne $fixture.Shape) {
      throw "Separator-relative column diagnostics must redact values and preserve empty fields"
    }
  }
}
foreach ($row in @(
    ("private`t" + (" " * 100)),
    ((" " * $columnSeparator.Length) + "private")
  )) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $columnSeparator, $row) "D:" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerColumnShape -cne "layout") {
    throw "Unsupported column layouts must remain rejected without value output"
  }
}
foreach ($fixture in @(
    [pscustomobject]@{
      Separator = "  $columnSeparator"
      Row = "x " + ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("Unrelated", "328010", "private instance", "0", "00000003", ""))
      Shape = "layout"
    }
    [pscustomobject]@{
      Separator = "  $columnSeparator"
      Row = "  " + ("{0,-20} {1,13} {2,-32} {3,7} {4,8} {5,8}" -f @("Unrelated", "328010", "private instance", "0", "00000003", "private"))
      Shape = "word-integer-words-integer-digits8-word"
    }
  )) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $fixture.Separator, $fixture.Row) "D:" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerColumnShape -cne $fixture.Shape) {
    throw "Column diagnostics must handle indentation and right alignment without accepting rows"
  }
}
Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $columnSeparator) "D:" | Out-Null
if ($script:filterManagerColumnShape -cne "unobserved") { throw "Column diagnostics must reset" }
$fixedWidthRows = @(
  ,@("WdFilter", "328010", "WdFilter Instance", "0", "0000000f", "")
  ,@("PROCMON24", "385200", "Process Monitor 24 Instance", "0", "0000000f", "")
  ,@("procmon24", "385200", "Process Monitor 24 Second", "0", "00000003", "0x00")
  ,@("PROCMON25", "385201.5", "Process Monitor 25 Instance", "1", "0x01", "0")
)
foreach ($format in @(
    "{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}",
    "{0,-20} {1,13} {2,-32} {3,7} {4,8} {5,8}"
  )) {
  foreach ($trim in @($false, $true)) {
    $rows = @(foreach ($values in $fixedWidthRows) {
        $row = $format -f $values
        if ($trim) { $row.TrimEnd() } else { $row }
      })
    if ((Get-ProcmonFilterManagerVolumeEvidence (
          @("Instances for D: Volume:", $instanceHeader, $columnSeparator) + $rows
        ) "D:") -cne "candidates:2;instances:3") {
      throw "Fixed-width fltmc instance rows must be counted without exposing names"
    }
  }
}
$shiftedRows = @(
  ("{0,-20} {1,-13} {2} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "Process Monitor 24 Instance With A Long Name", "0", "0000000f", ""))
  ("{0,-20} {1,-13} {2} {3} {4} {5}" -f @("PROCMON24", "385200", "Process Monitor 24 Second Instance Long Name", "0", "00000003", "0x00"))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("Unrelated", "328010", "Unrelated Instance 2", "0", "0000000f", ""))
)
if ((Get-ProcmonFilterManagerVolumeEvidence (
      @($instanceHeader, $columnSeparator) + $shiftedRows
    ) "D:") -cne "candidates:1;instances:2") {
  throw "Instance names wider than their column must shift later fields without breaking parsing"
}
$fixedWidthInvalidRows = @(
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "", "0", "0000000f", ""))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "private", "x", "0000000f", ""))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "private", "0", "000000001", ""))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "private", "0", "0000000f", "Detached"))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200.12345", "private", "0", "0000000f", ""))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "private", "0", "0000000f 0x00", "0x00"))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "private`tname", "0", "0000000f", ""))
  ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8} extra" -f @("PROCMON24", "385200", "private", "0", "0000000f", ""))
)
foreach ($row in $fixedWidthInvalidRows) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @($instanceHeader, $columnSeparator, $row) "D:" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerVolumeParseState -cne "row-shape") {
    throw "Malformed fixed-width instance rows must fail closed"
  }
}
$duplicateFixedWidthRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    $instanceHeader, $columnSeparator,
    ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "Same Instance", "0", "0000000f", "")),
    ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("procmon24", "385200", "same instance", "0", "0000000f", ""))
  ) "D:" | Out-Null
} catch { $duplicateFixedWidthRejected = $true }
if (-not $duplicateFixedWidthRejected) { throw "Duplicate fixed-width instances must fail closed" }
$duplicateChangedMetadataRejected = $false
try {
  Get-ProcmonFilterManagerVolumeEvidence @(
    $instanceHeader, $columnSeparator,
    ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("PROCMON24", "385200", "Same Instance", "0", "0000000f", "0")),
    ("{0,-20} {1,-13} {2,-32} {3,-7} {4,-8} {5,-8}" -f @("procmon24", "385200", "same instance", "1", "00000003", "1"))
  ) "D:" | Out-Null
} catch { $duplicateChangedMetadataRejected = $true }
if (-not $duplicateChangedMetadataRejected) {
  throw "Duplicate instances must fail closed when frame or flags differ"
}
$headerShapeFixtures = @(
  [pscustomobject]@{ Header = "Filter Altitude Instance Name Frame SprtFtrs Status"; Shape = "filter-altitude-instance-name-frame-sprtftrs-status" }
  [pscustomobject]@{ Header = "Filter Altitude Instance Name Frame SprtFtrs Flags"; Shape = "filter-altitude-instance-name-frame-sprtftrs-flags" }
  [pscustomobject]@{ Header = "Filter`tVLSTATUS Status FLAGS private"; Shape = "filter-vlstatus-status-flags-unknown" }
  [pscustomobject]@{ Header = "Filter VlStatusExtra Status: Flags=private"; Shape = "filter-unknown-unknown-unknown" }
  [pscustomobject]@{ Header = "Filter Altitude Instance Name Frame"; Shape = "filter-altitude-instance-name-frame" }
  [pscustomobject]@{ Header = "Filter Name Altitude Instance Name Frame SprtFtrs"; Shape = "filter-name-altitude-instance-name-frame-sprtftrs" }
  [pscustomobject]@{ Header = "Filter Volume Name Altitude Instance Name Frame"; Shape = "filter-volume-name-altitude-instance-name-frame" }
  [pscustomobject]@{ Header = "  FILTER`tAltitude  Instance Name  Frame  SprtFtrs "; Shape = "filter-altitude-instance-name-frame-sprtftrs" }
  [pscustomobject]@{ Header = "Filter unknown-value"; Shape = "filter-unknown" }
  [pscustomobject]@{ Header = "Filter C:\private"; Shape = "filter-unknown" }
  [pscustomobject]@{ Header = "Filter Name Private Altitude Instance Name Frame"; Shape = "filter-name-unknown-altitude-instance-name-frame" }
  [pscustomobject]@{ Header = "Filter private Altitude other Frame"; Shape = "filter-unknown-altitude-unknown-frame" }
  [pscustomobject]@{ Header = "Filter Name Altitude Instance Name Frame private"; Shape = "filter-name-altitude-instance-name-frame-unknown" }
  [pscustomobject]@{ Header = ("Filter " + ("private " * 15)); Shape = ("filter" + ("-unknown" * 15)) }
  [pscustomobject]@{ Header = ("Filter " + ("Name " * 16)); Shape = "token-limit" }
  [pscustomobject]@{ Header = ("Filter " + ("Name " * 15)); Shape = ("filter" + ("-name" * 15)) }
)
foreach ($fixture in $headerShapeFixtures) {
  $rejected = $false
  try {
    Get-ProcmonFilterManagerVolumeEvidence @(
      "Instances for D: Volume:", $fixture.Header, $volumeSeparator
    ) "D:\" | Out-Null
  } catch { $rejected = $true }
  if (-not $rejected -or $script:filterManagerVolumeParseState -cne "filter-heading" -or
    $script:filterManagerHeaderShape -cne $fixture.Shape) {
    throw "Unsupported headers must fail closed with bounded fixed-token diagnostics"
  }
}
Get-ProcmonFilterManagerVolumeEvidence @($volumeHeader, $volumeSeparator) "D:\" | Out-Null
if ($script:filterManagerHeaderShape -cne "unobserved") {
  throw "Header shape diagnostics must reset between queries"
}
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
    [StructLayout(LayoutKind.Sequential)]
    private struct InitCommonControls
    {
        public uint Size;
        public uint Classes;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ToolbarButton
    {
        public int Bitmap;
        public int Command;
        public byte State;
        public byte Style;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 6)]
        public byte[] Reserved;
        public IntPtr Data;
        public IntPtr Text;
    }
    [DllImport("comctl32.dll", EntryPoint = "InitCommonControlsEx", ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeCommonControls(ref InitCommonControls controls);
    public static IntPtr CreateToolbar(IntPtr parent)
    {
        var controls = new InitCommonControls
        {
            Size = (uint)Marshal.SizeOf(typeof(InitCommonControls)),
            Classes = 0x00000004
        };
        if (!InitializeCommonControls(ref controls))
            throw new InvalidOperationException("Synthetic toolbar common controls failed");
        var toolbar = Create(
            0, "ToolbarWindow32", "", 0x50000001, 8, 8, 240, 32,
            parent, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero
        );
        if (toolbar == IntPtr.Zero)
            throw new InvalidOperationException("Synthetic native toolbar creation failed");
        var size = Marshal.SizeOf(typeof(ToolbarButton));
        SendRaw(toolbar, 0x041E, new IntPtr(size), IntPtr.Zero);
        return toolbar;
    }
    public static void AddToolbarButton(IntPtr toolbar, int command, string value, bool enabled)
    {
        var text = Marshal.StringToHGlobalUni(value + "\0");
        var memory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ToolbarButton)));
        try
        {
            var stringIndex = SendRaw(toolbar, 0x044D, IntPtr.Zero, text).ToInt32();
            if (stringIndex < 0)
                throw new InvalidOperationException("Synthetic toolbar label could not be added");
            var button = new ToolbarButton
            {
                Bitmap = 0,
                Command = command,
                State = (byte)(enabled ? 0x04 : 0),
                Style = 0x40,
                Reserved = new byte[6],
                Data = IntPtr.Zero,
                Text = new IntPtr(stringIndex)
            };
            Marshal.StructureToPtr(button, memory, false);
            if (SendRaw(toolbar, 0x0414, new IntPtr(1), memory).ToInt32() == 0)
                throw new InvalidOperationException("Synthetic toolbar button could not be added");
        }
        finally
        {
            Marshal.FreeHGlobal(memory);
            Marshal.FreeHGlobal(text);
        }
    }
    [DllImport("user32.dll", EntryPoint = "SendMessageW", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern IntPtr SendText(
        IntPtr window, uint message, IntPtr wParam,
        [MarshalAs(UnmanagedType.LPWStr)] string text);
    [DllImport("user32.dll", EntryPoint = "SendMessageW", ExactSpelling = true)]
    private static extern IntPtr SendRaw(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ListViewColumn
    {
        public uint Mask;
        public int Format;
        public int Width;
        public IntPtr Text;
        public int TextMax;
        public int SubItem;
        public int Image;
        public int Order;
        public int MinimumWidth;
        public int DefaultWidth;
        public int IdealWidth;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ListViewItem
    {
        public uint Mask;
        public int Item;
        public int SubItem;
        public uint State;
        public uint StateMask;
        public IntPtr Text;
        public int TextMax;
        public int Image;
        public IntPtr Parameter;
        public int Indent;
        public int GroupId;
        public uint ColumnCount;
        public IntPtr Columns;
        public IntPtr ColumnFormats;
        public int Group;
    }
    public static void AddComboOption(IntPtr window, string value)
    {
        if (SendText(window, 0x0143, IntPtr.Zero, value).ToInt32() == -1)
            throw new InvalidOperationException("Synthetic combo option could not be added");
    }
    public static void AddListColumn(IntPtr window, int index, string value)
    {
        var text = Marshal.StringToHGlobalUni(value);
        var memory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ListViewColumn)));
        try
        {
            var column = new ListViewColumn
            {
                Mask = 0x000E,
                Width = 120,
                Text = text,
                TextMax = value.Length + 1,
                SubItem = index
            };
            Marshal.StructureToPtr(column, memory, false);
            if (SendRaw(window, 0x1061, new IntPtr(index), memory).ToInt32() != index)
                throw new InvalidOperationException("Synthetic list column could not be added");
        }
        finally
        {
            Marshal.FreeHGlobal(memory);
            Marshal.FreeHGlobal(text);
        }
    }
    public static void AddListCell(IntPtr window, int row, int columnIndex, string value, bool insert)
    {
        var text = Marshal.StringToHGlobalUni(value);
        var memory = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(ListViewItem)));
        try
        {
            var item = new ListViewItem
            {
                Mask = 0x0001,
                Item = row,
                SubItem = columnIndex,
                Text = text,
                TextMax = value.Length + 1
            };
            Marshal.StructureToPtr(item, memory, false);
            var result = SendRaw(
                window,
                (uint)(insert ? 0x104D : 0x1074),
                new IntPtr(row),
                memory
            ).ToInt32();
            if ((insert && result != row) || (!insert && result == 0))
                throw new InvalidOperationException("Synthetic list cell could not be added");
        }
        finally
        {
            Marshal.FreeHGlobal(memory);
            Marshal.FreeHGlobal(text);
        }
    }
    public static int GetButtonCheck(IntPtr window)
    {
        return SendRaw(window, 0x00F0, IntPtr.Zero, IntPtr.Zero).ToInt32();
    }
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
$nativeMenuLiteral = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
    $node.Value -match 'public static class ProcmonNativeMenu'
}, $true)
if ($null -eq $nativeMenuLiteral) {
  throw "Native Procmon control helper is missing"
}
Add-Type -AssemblyName Accessibility
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SyntheticOwnerDrawMenu
{
    [DllImport("user32.dll", EntryPoint = "CreatePopupMenu", ExactSpelling = true, SetLastError = true)]
    public static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AppendMenu(IntPtr menu, uint flags, IntPtr item, IntPtr data);
    [DllImport("user32.dll", EntryPoint = "DestroyMenu", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyMenu(IntPtr menu);
}
'@
Add-Type -TypeDefinition $nativeMenuLiteral.Value `
  -ReferencedAssemblies ([Accessibility.IAccessible].Assembly.Location)
$classProbeForm = [System.Windows.Forms.Form]::new()
try {
  $classProbeChild = [System.Windows.Forms.TextBox]::new()
  $classProbeForm.Controls.Add($classProbeChild)
  $classProbeRoot = $classProbeForm.Handle
  $classProbeChildHandle = $classProbeChild.Handle
  if (
    [ProcmonNativeMenu]::GetWindowClassKind($classProbeRoot, [uint32]$PID, $classProbeRoot) -cne "main" -or
    [ProcmonNativeMenu]::GetParentWindowClassKind($classProbeRoot, [uint32]$PID, $classProbeRoot) -cne "none" -or
    [ProcmonNativeMenu]::GetWindowClassKind($classProbeChildHandle, [uint32]$PID, $classProbeRoot) -cne "other" -or
    [ProcmonNativeMenu]::GetRootWindowClassKind($classProbeChildHandle, [uint32]$PID, $classProbeRoot) -cne "main" -or
    [ProcmonNativeMenu]::GetWindowStyleKind($classProbeChildHandle, [uint32]$PID) -cne "child" -or
    [ProcmonNativeMenu]::GetWindowStyleKind($classProbeChildHandle, [uint32]0) -cne "unavailable" -or
    [ProcmonNativeMenu]::GetWindowClassKind($classProbeRoot, [uint32]0, $classProbeRoot) -cne "other-process"
  ) {
    throw "Native window class categories must be bounded and process-scoped"
  }
} finally {
  $classProbeForm.Dispose()
}
$ownerDrawRootMenu = [SyntheticOwnerDrawMenu]::CreatePopupMenu()
$ownerDrawSubmenu = [SyntheticOwnerDrawMenu]::CreatePopupMenu()
$menuLabelPointer = [Runtime.InteropServices.Marshal]::StringToHGlobalUni("Drop Filtered Events")
$ownerDrawAttached = $false
try {
  if (
    $ownerDrawRootMenu -eq [IntPtr]::Zero -or
    $ownerDrawSubmenu -eq [IntPtr]::Zero -or
    -not [SyntheticOwnerDrawMenu]::AppendMenu(
      $ownerDrawSubmenu, 0, [IntPtr]::new(1), $menuLabelPointer
    ) -or
    -not [SyntheticOwnerDrawMenu]::AppendMenu(
      $ownerDrawRootMenu, 0x110, $ownerDrawSubmenu, [IntPtr]::new(123)
    )
  ) {
    throw "Synthetic owner-drawn menu fixture could not be created"
  }
  $ownerDrawAttached = $true
  $ownerDrawSnapshot = [ProcmonNativeMenu]::ReadItemMetadata($ownerDrawRootMenu, 0)
  $ownerDrawFlag = $false
  $ownerDrawTextItem = [ProcmonNativeMenu]::ReadItem(
    $ownerDrawRootMenu, 0, [ref]$ownerDrawFlag
  )
  $dropOwnerDrawFlag = $false
  $dropMenuSnapshot = [ProcmonNativeMenu]::ReadItem(
    $ownerDrawSnapshot.Submenu, 0, [ref]$dropOwnerDrawFlag
  )
  if (
    $null -eq $ownerDrawSnapshot -or
    -not $ownerDrawSnapshot.IsOwnerDrawn -or
    $ownerDrawSnapshot.Submenu -ne $ownerDrawSubmenu -or
    $null -ne $ownerDrawTextItem -or
    -not $ownerDrawFlag -or
    $null -eq $dropMenuSnapshot -or
    $dropOwnerDrawFlag -or
    $dropMenuSnapshot.Text -cne "Drop Filtered Events" -or
    -not $dropMenuSnapshot.IsEnabled
  ) {
    throw "Owner-drawn parent metadata did not preserve its safe submenu handle"
  }
  Write-Host "PASS AC-05: bounded native menu metadata traverses owner-drawn parents without reading item data"
} finally {
  [Runtime.InteropServices.Marshal]::FreeHGlobal($menuLabelPointer)
  if ($ownerDrawRootMenu -ne [IntPtr]::Zero) {
    [SyntheticOwnerDrawMenu]::DestroyMenu($ownerDrawRootMenu) | Out-Null
  }
  if (-not $ownerDrawAttached -and $ownerDrawSubmenu -ne [IntPtr]::Zero) {
    [SyntheticOwnerDrawMenu]::DestroyMenu($ownerDrawSubmenu) | Out-Null
  }
}
$nativeForm = [System.Windows.Forms.Form]::new()
$nativeForm.ShowInTaskbar = $false
$nativeForm.Opacity = 0.05
$nativeForm.Width = 640
$nativeForm.Height = 320
$nativeComboHandle = [SyntheticListCount]::Create(
  0, "ComboBox", "", 0x50200203, 8, 8, 220, 100,
  $nativeForm.Handle, [IntPtr]201, [IntPtr]::Zero, [IntPtr]::Zero
)
$nativeEditHandle = [SyntheticListCount]::Create(
  0, "Edit", "", 0x50000080, 8, 40, 220, 24,
  $nativeForm.Handle, [IntPtr]202, [IntPtr]::Zero, [IntPtr]::Zero
)
$nativeButtonHandle = [SyntheticListCount]::Create(
  0, "Button", "&Add", 0x50000003, 240, 8, 80, 24,
  $nativeForm.Handle, [IntPtr]203, [IntPtr]::Zero, [IntPtr]::Zero
)
$nativeDisabledButtonHandle = [SyntheticListCount]::Create(
  0, "Button", "&Remove", 0x58000003, 330, 8, 80, 24,
  $nativeForm.Handle, [IntPtr]205, [IntPtr]::Zero, [IntPtr]::Zero
)
$nativeListHandle = [SyntheticListCount]::Create(
  0, "SysListView32", "", 0x50000001, 8, 80, 560, 180,
  $nativeForm.Handle, [IntPtr]204, [IntPtr]::Zero, [IntPtr]::Zero
)
if (
  $nativeComboHandle -eq [IntPtr]::Zero -or
  $nativeEditHandle -eq [IntPtr]::Zero -or
  $nativeButtonHandle -eq [IntPtr]::Zero -or
  $nativeDisabledButtonHandle -eq [IntPtr]::Zero -or
  $nativeListHandle -eq [IntPtr]::Zero
) {
  throw "Synthetic native filter controls could not be created"
}
foreach ($option in @("Path", "is", "Include")) {
  [SyntheticListCount]::AddComboOption($nativeComboHandle, $option)
}
$nativeList = [System.Windows.Forms.ListView]::new()
[void]$nativeList.Handle
$nativeList.Dispose()
$nativeList = $nativeListHandle
foreach ($columnIndex in 0..3) {
  [SyntheticListCount]::AddListColumn(
    $nativeList,
    $columnIndex,
    @("Column", "Relation", "Value", "Action")[$columnIndex]
  )
}
[SyntheticListCount]::AddListCell($nativeList, 0, 0, "Path", $true)
[SyntheticListCount]::AddListCell($nativeList, 0, 1, "is", $false)
[SyntheticListCount]::AddListCell($nativeList, 0, 2, "C:\audit\canary.png", $false)
[SyntheticListCount]::AddListCell($nativeList, 0, 3, "Include", $false)
[SyntheticListCount]::AddListCell($nativeList, 1, 0, "Path", $true)
[SyntheticListCount]::AddListCell($nativeList, 1, 1, "is", $false)
[SyntheticListCount]::AddListCell($nativeList, 1, 2, "C:\audit\sentinel.png", $false)
[SyntheticListCount]::AddListCell($nativeList, 1, 3, "Exclude", $false)
$nativeForm.Show()
$nativeForm.Activate()
[System.Windows.Forms.Application]::DoEvents()
$nativeToolbarHandle = [SyntheticListCount]::CreateToolbar($nativeForm.Handle)
[SyntheticListCount]::AddToolbarButton($nativeToolbarHandle, 301, "Filter", $true)
[SyntheticListCount]::AddToolbarButton($nativeToolbarHandle, 302, "Other", $true)
[System.Windows.Forms.Application]::DoEvents()
try {
  $toolbarSnapshot = [ProcmonNativeMenu]::ReadNativeFilterToolbarCommand(
    $nativeToolbarHandle, [int]$PID
  )
  if (
    $toolbarSnapshot.ReadFailure -cne "none" -or
    $toolbarSnapshot.ButtonCount -ne 2 -or
    $toolbarSnapshot.ReadableLabelCount -ne 2 -or
    $toolbarSnapshot.LabelMatchCount -ne 1 -or
    $toolbarSnapshot.MatchCount -ne 1 -or
    -not $toolbarSnapshot.IsEnabled
  ) {
    throw "Native toolbar metadata did not identify one exact enabled Filter label"
  }
  $foreignToolbarSnapshot = [ProcmonNativeMenu]::ReadNativeFilterToolbarCommand(
    $nativeToolbarHandle, 0
  )
  if ($foreignToolbarSnapshot.ReadFailure -cne "owner-mismatch") {
    throw "Native toolbar metadata accepted a foreign process"
  }
  if ([ProcmonNativeMenu]::ReadNativeComboItemCount($nativeComboHandle, [int]$PID) -ne 3) {
    throw "Native combo count did not read the synthetic options"
  }
  if ([ProcmonNativeMenu]::CountNativeComboItemExact($nativeComboHandle, [int]$PID, "Path") -ne 1) {
    throw "Native combo exact option count was not unique"
  }
  [ProcmonNativeMenu]::SelectNativeComboItemExact($nativeComboHandle, [int]$PID, "Path")
  if ([ProcmonNativeMenu]::ReadNativeControlText($nativeComboHandle, [int]$PID, "combo", 256) -cne "Path") {
    throw "Native combo selection readback did not match"
  }
  [ProcmonNativeMenu]::SetNativeEditTextExact(
    $nativeEditHandle, [int]$PID, "C:\audit\canary.png"
  )
  if ([ProcmonNativeMenu]::ReadNativeControlText($nativeEditHandle, [int]$PID, "edit", 1024) -cne "C:\audit\canary.png") {
    throw "Native edit text readback did not match"
  }
  if ([ProcmonNativeMenu]::IsWindowEnabled($nativeDisabledButtonHandle)) {
    throw "Synthetic native button was expected to be disabled"
  }
  if ([ProcmonNativeMenu]::ReadNativeControlText(
      $nativeDisabledButtonHandle, [int]$PID, "button", 128, $true
    ) -cne "&Remove") {
    throw "Native disabled button caption could not be read for identification"
  }
  $disabledButtonClickRejected = $false
  try {
    [ProcmonNativeMenu]::ClickNativeButtonExact(
      $nativeDisabledButtonHandle, [int]$PID, "Remove"
    )
  } catch [System.InvalidOperationException] {
    $disabledButtonClickRejected = $true
  }
  if (-not $disabledButtonClickRejected) {
    throw "Native disabled button passed the click eligibility gate"
  }
  [ProcmonNativeMenu]::ClickNativeButtonExact($nativeButtonHandle, [int]$PID, "Add")
  [System.Windows.Forms.Application]::DoEvents()
  if ([SyntheticListCount]::GetButtonCheck($nativeButtonHandle) -ne 1) {
    throw "Native button activation did not toggle its synthetic checked state"
  }
  [ProcmonNativeMenu]::ClickNativeButtonWithMouseExact(
    $nativeButtonHandle,
    $nativeForm.Handle,
    [int]$PID,
    "Add"
  )
  [System.Windows.Forms.Application]::DoEvents()
  if ([SyntheticListCount]::GetButtonCheck($nativeButtonHandle) -ne 0) {
    throw "Native mouse button activation did not toggle its synthetic checked state"
  }
  if (
    [ProcmonNativeMenu]::ReadNativeListItemCount($nativeList, [int]$PID) -ne 2 -or
    [ProcmonNativeMenu]::ReadNativeListColumnCount($nativeList, [int]$PID) -ne 4
  ) {
    throw "Native list count or header count did not match the synthetic fixture"
  }
  if ([ProcmonNativeMenu]::SelectNativeListItemsExact($nativeList, [int]$PID, 2) -ne 2) {
    throw "Native list did not select all synthetic rows"
  }
  [ProcmonNativeMenu]::ClickNativeListItemExact(
    $nativeList,
    $nativeForm.Handle,
    [int]$PID
  )
  [System.Windows.Forms.Application]::DoEvents()
  if (-not [ProcmonNativeMenu]::IsNativeListFocusedExact(
      $nativeForm.Handle,
      $nativeList,
      [int]$PID
    )) {
    throw "Synthetic native list did not retain keyboard focus"
  }
  [ProcmonNativeMenu]::SendControlAShortcutExact(
    $nativeForm.Handle,
    $nativeList,
    [int]$PID
  )
  if (-not [ProcmonNativeMenu]::AreNativeListItemsSelectedExact($nativeList, [int]$PID, 2)) {
    throw "Native list keyboard selection did not match the synthetic row count"
  }
  $expectedCells = @("Path", "is", "C:\audit\canary.png", "Include")
  for ($columnIndex = 0; $columnIndex -lt $expectedCells.Count; $columnIndex++) {
    $actualCell = [ProcmonNativeMenu]::ReadNativeListItemText(
      $nativeList, [int]$PID, 0, $columnIndex, 1024
    )
    if ($actualCell -cne $expectedCells[$columnIndex]) {
      throw "Native list text did not match the synthetic four-column fixture"
    }
  }
} finally {
  if ($nativeToolbarHandle -ne [IntPtr]::Zero -and
    -not [SyntheticListCount]::DestroyWindow($nativeToolbarHandle)) {
    throw "Synthetic native toolbar cleanup failed"
  }
  $nativeForm.Close()
  $nativeForm.Dispose()
}
Write-Host "PASS AC-05: bounded native toolbar metadata reads exact labels and rejects foreign owners"
$menuForm = [System.Windows.Forms.Form]::new()
$menuForm.ShowInTaskbar = $false
$menuForm.Width = 320
$menuForm.Height = 180
$menuStrip = [System.Windows.Forms.MenuStrip]::new()
$filterMenuItem = [System.Windows.Forms.ToolStripMenuItem]::new("&Filter")
$dropMenuItem = [System.Windows.Forms.ToolStripMenuItem]::new("Drop Filtered Events")
[void]$filterMenuItem.DropDownItems.Add($dropMenuItem)
[void]$menuStrip.Items.Add($filterMenuItem)
$menuForm.MainMenuStrip = $menuStrip
[void]$menuForm.Controls.Add($menuStrip)
$menuForm.Show()
$menuForm.Activate()
[System.Windows.Forms.Application]::DoEvents()
try {
  if ([ProcmonNativeMenu]::GetForegroundWindow() -ne $menuForm.Handle) {
    throw "Synthetic menu form did not receive foreground activation"
  }
  $menuInput = [ProcmonNativeMenu]::SendAltFShortcut($menuForm.Handle, [int]$PID)
  if ($menuInput.State -ne "sent" -or $menuInput.Events -ne 4) {
    throw "Native Alt+F input did not satisfy the exact shortcut gate"
  }
  $menuDeadline = [DateTime]::UtcNow.AddSeconds(2)
  while (-not $filterMenuItem.DropDown.Visible -and [DateTime]::UtcNow -lt $menuDeadline) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 25
  }
  if (-not $filterMenuItem.DropDown.Visible) {
    throw "Native Alt+F input did not open the synthetic Filter menu"
  }
  if ($dropMenuItem.Text -cne "Drop Filtered Events") {
    throw "Synthetic Filter menu item label changed"
  }
  $filterMenuItem.DropDown.Close()
} finally {
  $menuForm.Close()
  $menuForm.Dispose()
}
$openFilterMenuFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Open-ProcmonFilterMenuFromMain"
}, $true)
if (
  $null -eq $openFilterMenuFunction -or
  ([regex]::Matches($openFilterMenuFunction.Extent.Text, 'SendAltFShortcut')).Count -ne 1 -or
  $openFilterMenuFunction.Extent.Text -notmatch '(?s)Set-VerifiedProcmonMainWindowForeground \$MainWindow \$Process "MAIN"[\s\S]*Set-Stage "find-filter-menu-item"[\s\S]*\$filterMenu = Wait-Element \$MainWindow \$filterMenuCondition 2 -AllowMissing[\s\S]*if \(\$null -eq \$filterMenu\) \{[\s\S]*Set-Stage "find-filter-toolbar-command"[\s\S]*NameProperty,[\s\S]*"Filter"[\s\S]*\$filterToolbarCandidates.Count -gt 64[\s\S]*candidateState.ProcessId -ne \$Process.Id[\s\S]*candidateState.Name -cne "Filter"[\s\S]*ControlType\]::Button[\s\S]*ControlType\]::MenuItem[\s\S]*candidateParent.Current.ProcessId -ne \$Process.Id[\s\S]*ControlType\]::ToolBar[\s\S]*candidateState.IsEnabled[\s\S]*candidateState.IsOffscreen[\s\S]*InvokePattern\]::Pattern[\s\S]*\$verifiedFilterToolbarCommands.Count -gt 1[\s\S]*GetForegroundWindow\(\) -ne \$mainHandle[\s\S]*InvokePattern.Invoke\(\)[\s\S]*Wait-ProcessMenu \$Process[\s\S]*\$toolbarPopupState.ProcessId -ne \$Process.Id[\s\S]*return \$toolbarPopup[\s\S]*SendAltFShortcut\(\s*\$mainHandle,\s*\$Process\.Id\s*\)[\s\S]*\$shortcutInput.State -ne "sent" -or \$shortcutInput.Events -ne 4[\s\S]*Wait-ProcessMenu \$Process[\s\S]*\$menuState.ProcessId -ne \$Process.Id[\s\S]*return \$menu[\s\S]*\}\s*\r?\n\s*Set-Stage "verify-filter-menu-item"\s+\$filterMenuState = \$filterMenu\.Current[\s\S]*TryGetCurrentPattern\([\s\S]*InvokePattern\]::Pattern'
) {
  throw "Filter activation must verify an exact toolbar command or use the gated keyboard fallback"
}
Write-Host "PASS AC-05: Filter command activation verifies a same-process exact toolbar command or gated fallback"
$nativeToolbarPath = $openFilterMenuFunction.Extent.Text
if (
  $nativeToolbarPath -notmatch '(?s)ReadNativeChildSummary\(\s*\$mainHandle,\s*\$Process\.Id,\s*256\s*\)' -or
  $nativeToolbarPath -notmatch '(?s)Kind -eq "toolbar"[\s\S]*\$nativeToolbarHandles\.Count -eq 1' -or
  $nativeToolbarPath -notmatch '(?s)GetWindowProcessId\(\$nativeToolbarHandle\) -eq \$Process\.Id[\s\S]*AutomationElement\]::FromHandle' -or
  $nativeToolbarPath -notmatch '(?s)nativeToolbarState\.ControlType -eq[\s\S]*ControlType\]::ToolBar' -or
  $nativeToolbarPath -notmatch '(?s)candidateState\.Name -cne "Filter"[\s\S]*candidateState\.IsEnabled[\s\S]*candidateState\.IsOffscreen[\s\S]*ControlType\]::ToolBar' -or
  $nativeToolbarPath -notmatch '(?s)\$nativeToolbarCommands\.Count -gt 1[\s\S]*\$nativeToolbarCommands\.Count -eq 1[\s\S]*invoke-native-filter-toolbar-command[\s\S]*GetForegroundWindow\(\) -ne \$mainHandle[\s\S]*Wait-ProcessMenu \$Process'
) {
  throw "Native toolbar fallback must verify bounded same-process exact Filter UIA state before invoking"
}
Write-Host "PASS AC-05: native ToolbarWindow32 discovery is bounded and exact-label gated"
$nativeToolbarMetadataStart = $sourceText.IndexOf(
  "public static NativeToolbarCommandSnapshot ReadNativeFilterToolbarCommand",
  [StringComparison]::Ordinal
)
$nativeToolbarMetadataEnd = if ($nativeToolbarMetadataStart -ge 0) {
  $sourceText.IndexOf(
    "private static string NormalizeNativeButtonLabel",
    $nativeToolbarMetadataStart,
    [StringComparison]::Ordinal
  )
} else { -1 }
if (
  $nativeToolbarMetadataStart -lt 0 -or
  $nativeToolbarMetadataEnd -le $nativeToolbarMetadataStart
) {
  throw "Native toolbar metadata probe is missing"
}
$nativeToolbarMetadataSource = $sourceText.Substring(
  $nativeToolbarMetadataStart,
  $nativeToolbarMetadataEnd - $nativeToolbarMetadataStart
)
if (
  $nativeToolbarMetadataSource -notmatch '(?s)TB_BUTTONCOUNT[\s\S]*TB_GETBUTTON[\s\S]*TB_GETBUTTONTEXTW' -or
  $nativeToolbarMetadataSource -notmatch '(?s)ToolbarWindow32[\s\S]*MaximumToolbarButtons[\s\S]*MaximumToolbarTextCharacters' -or
  $nativeToolbarMetadataSource -notmatch '(?s)SendMessageTimeoutRaw[\s\S]*ReadProcessMemory[\s\S]*WriteProcessMemory' -or
  $nativeToolbarMetadataSource -notmatch '(?s)"Filter"[\s\S]*StringComparison\.Ordinal[\s\S]*TBSTATE_ENABLED[\s\S]*TBSTATE_HIDDEN' -or
  $nativeToolbarMetadataSource -match 'SendInput|WM_COMMAND|accDoDefaultAction'
) {
  throw "Native toolbar metadata must be bounded, exact-label, ownership-checked and read-only"
}
Write-Host "PASS AC-05: native ToolbarWindow32 metadata remains bounded, exact-label and read-only"
$accessibleToolbarPath = $openFilterMenuFunction.Extent.Text
if (
  $sourceText -notmatch '(?s)public static AccessibleToolbarCommandSnapshot ReadAccessibleFilterToolbarCommand\([\s\S]*ToolbarWindow32[\s\S]*AccessibleObjectFromWindow\([\s\S]*AccessibleClientObjectId[\s\S]*MaximumAccessibleMenuItems[\s\S]*"Filter"[\s\S]*role != 0x2B[\s\S]*get_accState[\s\S]*get_accDefaultAction' -or
  $sourceText -notmatch '(?s)public static void InvokeAccessibleFilterToolbarCommand\([\s\S]*GetForegroundWindow\(\) != expectedForegroundWindow[\s\S]*ReadAccessibleFilterToolbarCommand\([\s\S]*snapshot\.LabelMatchCount != 1[\s\S]*snapshot\.MatchCount != 1[\s\S]*!snapshot\.IsEnabled[\s\S]*!snapshot\.HasDefaultAction[\s\S]*accDoDefaultAction' -or
  $accessibleToolbarPath -notmatch '(?s)ReadAccessibleFilterToolbarCommand\([\s\S]*LabelMatchCount -eq 1[\s\S]*MatchCount -eq 1[\s\S]*IsEnabled[\s\S]*HasDefaultAction[\s\S]*invoke-accessible-filter-toolbar-command[\s\S]*GetForegroundWindow\(\) -ne \$mainHandle[\s\S]*InvokeAccessibleFilterToolbarCommand\([\s\S]*Wait-ProcessMenu \$Process'
) {
  throw "MSAA toolbar activation must verify one exact enabled same-process Filter command and action"
}
Write-Host "PASS AC-05: MSAA toolbar command is exact-label, enabled-state, and foreground gated"
if (
  $sourceText -notmatch '(?s)function Set-Stage\(\[string\]\$Name\) \{\s*\$script:stage = \$Name' -or
  $sourceText -notmatch 'PROC_MON_FILTER_FAILED_STAGE=\$script:stage'
) {
  throw "Failure-stage reporting must read the same script-scoped stage that progress updates write"
}
Write-Host "PASS AC-05: failed-stage diagnostics report the current script-scoped stage"
$processMenuFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Wait-ProcessMenu"
}, $true)
if (
  $null -eq $processMenuFunction -or
  $processMenuFunction.Extent.Text -notmatch '(?s)NameProperty,[\s\S]*"Drop Filtered Events"[\s\S]*ControlTypeProperty,[\s\S]*ControlType\]::MenuItem[\s\S]*\$window\.FindAll\([\s\S]*TreeScope\]::Descendants[\s\S]*\$dropItems\.Count -gt 64[\s\S]*\$dropItemState\.ProcessId -ne \$Process\.Id[\s\S]*\$dropItemState\.Name -cne "Drop Filtered Events"[\s\S]*ControlType\]::MenuItem[\s\S]*\$seenDropItemRuntimeIds\.Add\(\$dropItemRuntimeId\)[\s\S]*PROC_MON_FILTER_PROCESS_DROP_ITEM_SCAN='
) {
  throw "Procmon direct exact-label menu-item scans must be bounded and same-process"
}
Write-Host "PASS AC-05: exact Drop Filtered Events UIA item scans are bounded and process-scoped"
$nativeFilterButtonFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Invoke-ProcmonNativeFilterButton"
}, $true)
if (
  $null -eq $nativeFilterButtonFunction -or
  $nativeFilterButtonFunction.Extent.Text -notmatch '(?s)\[ProcmonNativeMenu\]::GetWindowProcessId\(\$root\) -ne \$ProcessId[\s\S]*IsWindowVisible\(\$root\)[\s\S]*IsWindowEnabled\(\$root\)[\s\S]*SetForegroundWindow\(\$root\)[\s\S]*GetForegroundWindow\(\)[\s\S]*\$foregroundHandle -eq \$root[\s\S]*GetWindowProcessId\(\$foregroundHandle\) -eq \$ProcessId[\s\S]*\$foregroundGate -ne "passed"[\s\S]*IsWindowVisible\(\$button\)[\s\S]*IsWindowEnabled\(\$button\)[\s\S]*ClickNativeButtonExact'
) {
  throw "Native filter buttons must require verified dialog foreground, process ownership, visibility, and enabled state"
}
Write-Host "PASS AC-05: native filter buttons require verified same-process dialog foreground"
if (
  $openFilterMenuFunction.Extent.Text -notmatch '(?s)GetMenuOwnerWindow\([\s\S]*\[ref\]\$menuModeActive[\s\S]*if \(\$guiThreadInfoAvailable -and \$menuWindowSameProcess\)[\s\S]*Get-AccessibleDropMenuSnapshot[\s\S]*\$mainHandle \$Process\.Id \$true "filter-menu-fallback"[\s\S]*ReadFocusSnapshot\(\$mainHandle\)[\s\S]*CaptureWindow[\s\S]*MenuOwnerWindow[\s\S]*\$captureVisible -and -not \$menuLoopHandles\.Contains\(\$captureHandle\)[\s\S]*\$snapshotMenuOwnerVisible[\s\S]*Write-ProcmonNativeMenuSummary[\s\S]*-Source "active-menu-loop"[\s\S]*Write-ProcmonMenuLoopUiaSummary \$focusHandle \$Process "focus"[\s\S]*Write-ProcmonMenuLoopUiaSummary \$captureHandle \$Process "capture"[\s\S]*Write-ProcmonMenuLoopUiaSummary \$snapshotMenuOwnerHandle \$Process "menu-owner"[\s\S]*Write-ProcmonMenuLoopUiaSummary \$mainHandle \$Process "main-after-shortcut"'
) {
  throw "Fallback diagnostics must inspect bounded fixed-label UIA/MSAA data on visible same-process windows"
}
$menuLoopAccessibleBlock = [regex]::Match(
  $openFilterMenuFunction.Extent.Text,
  '(?s)\$accessibleHandles = .*?Write-ProcmonMenuLoopUiaSummary \$focusHandle'
)
if (
  -not $menuLoopAccessibleBlock.Success -or
  $menuLoopAccessibleBlock.Value -notmatch 'Role = "focus"' -or
  $menuLoopAccessibleBlock.Value -notmatch 'Role = "capture"' -or
  $menuLoopAccessibleBlock.Value -notmatch 'Role = "menu-owner"' -or
  $menuLoopAccessibleBlock.Value -notmatch 'GetWindowProcessId\(\$accessibleWindow\) -ne \$Process\.Id' -or
  $menuLoopAccessibleBlock.Value -notmatch 'IsWindowVisible\(\$accessibleWindow\)' -or
  $menuLoopAccessibleBlock.Value -notmatch '\$accessibleHandlesSeen\.Add\(\$accessibleWindow\)' -or
  $menuLoopAccessibleBlock.Value -notmatch 'ReadAccessibleDropMenuState\([\s\S]*\$accessibleWindow' -or
  $menuLoopAccessibleBlock.Value -notmatch 'object:\$menuObject' -or
  $openFilterMenuFunction.Extent.Text -notmatch '(?s)IsWindowVisible\(\$mainHandle\)[\s\S]*GetWindowProcessId\(\$mainHandle\) -eq \$Process\.Id[\s\S]*ReadAccessibleDropMenuState\(\s*\$mainHandle,\s*\[uint32\]\$Process\.Id,\s*\$false\s*\)[\s\S]*role:main-after-shortcut;object:client'
) {
  throw "MSAA must inspect unique visible same-process menu-loop windows and the main client object using fixed labels"
}
$menuLoopUiaFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ProcmonMenuLoopUiaSummary"
}, $true)
if (
  $null -eq $menuLoopUiaFunction -or
  $menuLoopUiaFunction.Extent.Text -notmatch 'GetWindowProcessId\(\$WindowHandle\) -eq \$Process\.Id' -or
  $menuLoopUiaFunction.Extent.Text -notmatch 'IsWindowVisible\(\$WindowHandle\)' -or
  $menuLoopUiaFunction.Extent.Text -notmatch '(?s)FromHandle\(\$WindowHandle\)[\s\S]*\$window\.Current\.ProcessId -eq \$Process\.Id[\s\S]*FindAll\([\s\S]*\$menuItems\.Count -le 64' -or
  $menuLoopUiaFunction.Extent.Text -notmatch '(?s)NameProperty,[\s\S]*"Drop Filtered Events"[\s\S]*\$dropLabelItems\.Count -le 64[\s\S]*\$dropLabelState\.ProcessId -ne \$Process\.Id[\s\S]*\$dropLabelState\.Name -cne "Drop Filtered Events"[\s\S]*\$dropLabelState\.ControlType -eq[\s\S]*ControlType\]::MenuItem[\s\S]*\$dropLabelState\.IsEnabled' -or
  $menuLoopUiaFunction.Extent.Text -notmatch '\$itemState\.ProcessId -ne \$Process\.Id' -or
  $menuLoopUiaFunction.Extent.Text -notmatch '(?s)switch -CaseSensitive \(\$itemState\.Name\)[\s\S]*"Drop Filtered Events" \{ \$drops\+\+' -or
  $menuLoopUiaFunction.Extent.Text -notmatch 'ValidateSet\("main-after-shortcut", "focus", "capture", "menu-owner"\)'
) {
  throw "Menu-loop UIA inspection must be bounded, same-process, and exact-label only"
}
$topLevelWindowCategoryFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ProcmonTopLevelWindowCategories"
}, $true)
if (
  $null -eq $topLevelWindowCategoryFunction -or
  $topLevelWindowCategoryFunction.Extent.Text -notmatch '(?s)GetProcessTopLevelWindows\(\s*\$Process\.Id,\s*257\s*\)[\s\S]*\$handles\.Length -gt 256[\s\S]*GetWindowProcessId\(\$handle\) -ne \$Process\.Id[\s\S]*IsWindowVisible\(\$handle\)[\s\S]*IsWindowEnabled\(\$handle\)[\s\S]*GetWindowClassKind\([\s\S]*GetWindowStyleKind\([\s\S]*PROC_MON_FILTER_NATIVE_TOPLEVEL=' -or
  $sourceText -notmatch '(?s)function Find-ProcmonNativeFilterDialog[\s\S]*Write-ProcmonTopLevelWindowCategories \$Process \$MainWindowHandle[\s\S]*GetProcessTopLevelWindows'
) {
  throw "Filter-dialog discovery must retain only bounded same-process top-level class and style categories"
}
$staticTextSummaryFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ProcmonNativeChildSummary"
}, $true)
if (
  $null -eq $staticTextSummaryFunction -or
  $sourceText -notmatch '(?s)expectedKind == "static" && actualClassName == "Static"' -or
  $staticTextSummaryFunction.Extent.Text -notmatch '(?s)"static"\s*\{[\s\S]*ReadNativeControlText\([\s\S]*"static"[\s\S]*256[\s\S]*Get-ProcmonStaticTextCategories[\s\S]*\}' -or
  $staticTextSummaryFunction.Extent.Text -notmatch 'PROC_MON_FILTER_STATIC_TEXT=source:\$Source;controls:\$staticTextControls;categories:\$reportedCategories' -or
  $staticTextSummaryFunction.Extent.Text -match 'PROC_MON_FILTER_STATIC_TEXT=.*\$staticText\b'
) {
  throw "Procmon dialog static text must be same-process, bounded, and reduced to fixed categories"
}
$missingSnapshotRecoveryFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Resolve-ProcmonMissingSnapshotDialog"
}, $true)
if (
  $null -eq $missingSnapshotRecoveryFunction -or
  $missingSnapshotRecoveryFunction.Extent.Text -notmatch '(?s)GetProcessTopLevelWindows\(\s*\$Process\.Id,\s*257\s*\)[\s\S]*ReadNativeChildSummary\([\s\S]*256[\s\S]*An error occurred opening the snapshot[\s\S]*GetFolderPath\("UserProfile"\)[\s\S]*GetExtension\(\$snapshotPath\) -ine "\.pml"[\s\S]*File\]::Exists\(\$snapshotPath\)[\s\S]*GetForegroundWindow\(\)[\s\S]*ClickNativeButtonExact[\s\S]*"OK"[\s\S]*button:unique-enabled-ok' -or
  $missingSnapshotRecoveryFunction.Extent.Text -match 'WriteLine\([\s\S]{0,300}\$snapshotPath' -or
  $sourceText -notmatch '(?s)function Open-FilterDialogByShortcut[\s\S]*Resolve-ProcmonMissingSnapshotDialog \$Process \$mainWindowHandle[\s\S]*SendControlLShortcut[\s\S]*Resolve-ProcmonMissingSnapshotDialog \$Process \$mainWindowHandle[\s\S]*SendControlLShortcut'
) {
  throw "Only a unique verified missing profile PML dialog may be dismissed before one shortcut retry"
}
$accessibleDropReader = [regex]::Match(
  $sourceText,
  '(?s)public static AccessibleMenuSnapshot ReadAccessibleDropMenuState\(.*?public static AccessibleMenuSnapshot ReadAccessibleFilterMenuSummary'
)
if (
  -not $accessibleDropReader.Success -or
  $accessibleDropReader.Value -notmatch 'Queue<AccessibleNode>' -or
  $accessibleDropReader.Value -notmatch 'MaximumAccessibleMenuItems' -or
  $accessibleDropReader.Value -notmatch 'node\.Accessible\.get_accChild\(child\)' -or
  $accessibleDropReader.Value -notmatch 'node\.Depth \+ 1' -or
  $accessibleDropReader.Value -notmatch '(?s)if \(role == MenuItemRole\)[\s\S]*snapshot\.MatchCount\+\+[\s\S]*get_accState\(child\)' -or
  $accessibleDropReader.Value -notmatch 'snapshot\.LabelMatchCount\+\+' -or
  $accessibleDropReader.Value -notmatch 'node\.Depth >= 3' -or
  $accessibleDropReader.Value -notmatch '(?s)LabelMatchCount == 0[\s\S]*"no-match"[\s\S]*LabelMatchCount != 1[\s\S]*"duplicate-match"[\s\S]*MatchCount != 1[\s\S]*"role-mismatch"' -or
  $accessibleDropReader.Value -notmatch '(?s)catch \(ArgumentException\)[\s\S]*snapshot\.ReadFailure = "object-invalid"' -or
  $sourceText -notmatch 'nodes:\$\(\$focusAccessible\.NodesVisited\);items:\$\(\$focusAccessible\.ItemCount\);label-matches:\$\(\$focusAccessible\.LabelMatchCount\)'
) {
  throw "MSAA label candidates must be counted independently and state reads must require the exact menu-item role"
}
Write-Host "PASS AC-05: MSAA exact-label candidates remain read-only and role-gated"
$nativeMenuSummaryFunction = $ast.Find({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Write-ProcmonNativeMenuSummary"
}, $true)
if (
  $null -eq $nativeMenuSummaryFunction -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'GetWindowProcessId\(\$windowHandle\) -ne \$Process\.Id' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'GetMenu\(\$windowHandle\)' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'GetMenuItemCount' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'IsMenu\(\[IntPtr\]\$candidate\.Handle\)' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'invalidMenuHandles\+\+' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'ReadItem' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch '(?s)\[string\]::Equals\([\s\S]*"Drop Filtered Events"[\s\S]*StringComparison\]::Ordinal[\s\S]*\$dropMatches\+\+' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch '\$candidate\.Depth -lt 2' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch '\$items \+ \$itemCount -gt 256' -or
  $nativeMenuSummaryFunction.Extent.Text -notmatch 'drop:\$\(\[Math\]::Min\(\$dropMatches, 99\)\)' -or
  $nativeMenuSummaryFunction.Extent.Text -match 'SendMessage|PostMessage|SendKeys|Invoke\(|Toggle\('
) {
  throw "Active menu traversal must be same-process, bounded, fixed-label, and read-only"
}
if ($nativeMenuSummaryFunction.Extent.Text -notmatch 'invalid-handles:\$\(\[Math\]::Min\(\$invalidMenuHandles, 99\)\)') {
  throw "Native menu diagnostics must distinguish invalid handles from unreadable items"
}
Write-Host "PASS AC-05: fallback menu diagnostics inspect bounded fixed-label menus on visible same-process windows only"
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
      "Get-ConfigSaveWindowDisposition",
      "Wait-ProcessMenu",
      "Wait-KeyboardFocus",
      "ConvertTo-SendKeysLiteral"
    )
}, $true)
if ($functions.Count -ne 10) {
  throw "Expected the configuration file observation functions"
}
foreach ($function in $functions) {
  . ([scriptblock]::Create($function.Extent.Text))
}

$windowDispositionCases = @(
  [pscustomobject]@{ Arguments = @(20, 10, 200, 100, $true, $false); Expected = "other-process" }
  [pscustomobject]@{ Arguments = @(10, 10, 0, 100, $true, $false); Expected = "no-handle" }
  [pscustomobject]@{ Arguments = @(10, 10, 100, 100, $true, $false); Expected = "main-window" }
  [pscustomobject]@{ Arguments = @(10, 10, 200, 100, $false, $false); Expected = "disabled" }
  [pscustomobject]@{ Arguments = @(10, 10, 200, 100, $true, $true); Expected = "offscreen" }
  [pscustomobject]@{ Arguments = @(10, 10, 200, 100, $true, $false); Expected = "eligible" }
)
foreach ($fixture in $windowDispositionCases) {
  $windowDispositionArguments = $fixture.Arguments
  if ((Get-ConfigSaveWindowDisposition @windowDispositionArguments) -cne $fixture.Expected) {
    throw "Configuration save window disposition must classify only bounded UIA state"
  }
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
