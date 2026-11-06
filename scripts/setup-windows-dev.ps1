$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
  $issues = [System.Collections.Generic.List[string]]::new()

  function Get-CommandVersion([string]$name, [string[]]$arguments) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $command) {
      $issues.Add("$name is not installed")
      return $null
    }

    $output = & $command.Source @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
      $issues.Add("$name could not run successfully")
      return $null
    }
    return ($output | Out-String).Trim()
  }

  $nodeVersion = Get-CommandVersion "node" @("--version")
  if ($nodeVersion -and $nodeVersion -ne "v24.22.0") {
    $issues.Add("Node.js must be v24.22.0; found $nodeVersion")
  }

  $pnpmVersion = Get-CommandVersion "pnpm" @("--version")
  if ($pnpmVersion -and $pnpmVersion -ne "12.14.0") {
    $issues.Add("pnpm must be 12.14.0; found $pnpmVersion")
  }

  $rustVersion = Get-CommandVersion "rustc" @("--version")
  if ($rustVersion -and $rustVersion -notmatch '\b1\.99\.1\b') {
    $issues.Add("Rust must be 1.99.1; found $rustVersion")
  }

  $null = Get-CommandVersion "cargo" @("--version")

  $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
  $hasMsvc = $false
  if (Test-Path $vswhere) {
    $vsInstall = & $vswhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $hasMsvc = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($vsInstall | Out-String).Trim())
  }
  if (-not $hasMsvc) {
    $issues.Add("Visual Studio C++ Build Tools (MSVC x64/x86) are missing")
  }

  $webViewRoots = @(
    (Join-Path ${env:ProgramFiles(x86)} "Microsoft\EdgeWebView\Application"),
    (Join-Path $env:ProgramFiles "Microsoft\EdgeWebView\Application")
  ) | Where-Object { $_ -and (Test-Path $_) }
  $hasWebView2 = $false
  foreach ($root in $webViewRoots) {
    if (Get-ChildItem $root -Filter "msedgewebview2.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) {
      $hasWebView2 = $true
      break
    }
  }
  if (-not $hasWebView2) {
    $issues.Add("Microsoft Edge WebView2 Runtime is missing")
  }

  if ($issues.Count -gt 0) {
    Write-Error ("Windows development prerequisites are not ready:`n - " + ($issues -join "`n - ") + "`nSee README.md > Development environment for installation steps.")
    exit 1
  }

  Write-Host "Installing frontend dependencies from pnpm-lock.yaml..."
  & pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) {
    throw "pnpm install --frozen-lockfile failed with exit code $LASTEXITCODE"
  }

  Write-Host "Fetching Rust dependencies from Cargo.lock..."
  & cargo fetch --locked
  if ($LASTEXITCODE -ne 0) {
    throw "cargo fetch --locked failed with exit code $LASTEXITCODE"
  }

  Write-Host "Building the frontend..."
  & pnpm run build
  if ($LASTEXITCODE -ne 0) {
    throw "pnpm run build failed with exit code $LASTEXITCODE"
  }

  Write-Host "Testing the Rust workspace..."
  & cargo test --workspace --locked
  if ($LASTEXITCODE -ne 0) {
    throw "cargo test --workspace --locked failed with exit code $LASTEXITCODE"
  }

  Write-Host "Windows development environment is ready."
}
finally {
  Pop-Location
}
