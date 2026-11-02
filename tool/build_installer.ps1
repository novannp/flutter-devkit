# Builds the release and dist/DevKit-Setup.exe. Needs Inno Setup 6 (winget install JRSoftware.InnoSetup).
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

if (-not $SkipBuild) {
  fvm flutter build windows --release --no-tree-shake-icons
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([\d.]+)').Matches[0].Groups[1].Value
$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found: winget install JRSoftware.InnoSetup' }

& $iscc "/DAppVersion=$version" windows\installer\setup.iss
exit $LASTEXITCODE
