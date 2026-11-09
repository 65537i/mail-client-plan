param(
  [switch]$Capture,
  [ValidateSet("untouched", "touched")][string]$Scenario = "untouched"
)

$ErrorActionPreference = "Stop"
if ($env:OS -cne "Windows_NT") { throw "ETW controls require Windows" }
$compiler = Get-Command cl.exe -ErrorAction Stop
$temporary = Join-Path ([IO.Path]::GetTempPath()) ("mail-client-etw-build-" + [guid]::NewGuid().ToString("N"))
[IO.Directory]::CreateDirectory($temporary) | Out-Null
try {
  $executable = Join-Path $temporary "etw-controls.exe"
  $object = Join-Path $temporary "etw-controls.obj"
  $source = Join-Path $PSScriptRoot "windows-etw-controls.cpp"
  & $compiler.Source /nologo /EHsc /std:c++20 /W4 /WX /DUNICODE /D_UNICODE `
    "/Fo$object" "/Fe$executable" $source /link advapi32.lib tdh.lib ole32.lib
  if ($LASTEXITCODE -ne 0) { throw "ETW controls compilation failed" }
  & $executable --self-test
  if ($LASTEXITCODE -ne 0) { throw "ETW controls fixtures failed" }
  if ($Capture) {
    & $executable --capture-controls $Scenario
    $expectedExit = if ($Scenario -ceq "touched") { 2 } else { 0 }
    if ($LASTEXITCODE -ne $expectedExit) { throw "ETW controls capture or expected rejection failed" }
  }
} finally {
  Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction Stop
}
