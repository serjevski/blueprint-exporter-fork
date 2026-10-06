# Publish the mod as a versioned zip archive.
#
# Reads the version from info.json, zips the mod root (minus VCS and build
# artifacts) into publish/, and drops a copy into %APPDATA%\Factorio\mods\.
#
# Usage:  .\publish.ps1 [-NoModsCopy]

[CmdletBinding()]
param(
  [switch]$NoModsCopy
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

$infoPath = Join-Path $root "info.json"
if (-not (Test-Path $infoPath)) {
  throw "info.json not found at $infoPath"
}
$info = Get-Content -Raw -Path $infoPath | ConvertFrom-Json
$version = $info.version
if (-not $version) { throw "info.json has no version field" }

$modName = "blueprint-exporter"
$stageName = "$modName`_$version"
$outDir = Join-Path $root "publish"
$stageDir = Join-Path $env:TEMP $stageName
$zipPath = Join-Path $outDir "$stageName.zip"

$excludeDirs = @(".git", ".vscode", ".github", ".dev-test", "publish")
$excludeFiles = @(".gitattributes", ".gitignore")

Write-Host "Staging $modName v$version"

if (Test-Path $stageDir) { Remove-Item -Recurse -Force $stageDir }
New-Item -ItemType Directory -Path $stageDir | Out-Null

Get-ChildItem -Path $root -Force | ForEach-Object {
  $name = $_.Name
  if ($_.PSIsContainer) {
    if ($excludeDirs -contains $name) { return }
  } else {
    if ($excludeFiles -contains $name) { return }
  }
  Copy-Item -Recurse -Force -Path $_.FullName -Destination $stageDir
}

if (-not (Test-Path $outDir)) {
  New-Item -ItemType Directory -Path $outDir | Out-Null
}
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }

Compress-Archive -Path $stageDir -DestinationPath $zipPath
Remove-Item -Recurse -Force $stageDir

$size = (Get-Item $zipPath).Length
Write-Host ("Created {0} ({1:N0} bytes)" -f $zipPath, $size)

if (-not $NoModsCopy) {
  $modsDir = Join-Path $env:APPDATA "Factorio\mods"
  if (Test-Path $modsDir) {
    Copy-Item -Force -Path $zipPath -Destination $modsDir
    Write-Host "Copied into $modsDir"
  } else {
    Write-Warning "Mods folder $modsDir not found; skipped copy"
  }
}
