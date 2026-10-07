# Delete blueprint files under p/ and g/ that are not listed in manifest.json.
#
# The mod writes manifest.json with the list of every file it produced.  A
# blueprint deleted in game leaves its .txt/.json behind: the next export
# neither writes nor removes them (Factorio Lua cannot delete files).  This
# script removes exactly those orphans.
#
# Usage:
#   .\clean-orphans.ps1 <directory>
#   .\clean-orphans.ps1 <directory> -WhatIf
#
#   -WhatIf  only report what would be deleted (no files removed)
#
# Runs on PowerShell 5.1 and 7 alike.

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Root
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# Read the file as UTF-8.  -Encoding Byte was dropped in PS 7; reading without
# it would apply the ANSI code page on 5.1 and mangle every non-ASCII name.
function Read-JsonText([string]$Path) {
  return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
}

# The .NET file APIs resolve a relative path against the process working
# directory, which does not follow Set-Location.  Anchor to PowerShell's
# location instead.
function Resolve-FullPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  $base = (Get-Location -PSProvider FileSystem).ProviderPath
  return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $Path))
}

$root = Resolve-FullPath $Root
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
  throw "directory not found: $root"
}

$manifestPath = Join-Path $root 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "manifest.json not found in $root"
}

$manifest = (Read-JsonText $manifestPath) | ConvertFrom-Json

# An unknown manifest format must not turn into "delete everything": a missing
# files array is an error, not an empty keep-set.
$filesProp = $manifest.PSObject.Properties['files']
if ($null -eq $filesProp -or $null -eq $filesProp.Value) {
  throw "manifest.json has no files array: refusing to clean anything"
}

# Ordinal comparison: the manifest holds the exact names the export wrote.
# Forward slashes are what the manifest uses.
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($f in @($filesProp.Value)) { [void]$seen.Add([string]$f) }

$kept = 0
$deleted = 0

foreach ($subdir in @('p', 'g')) {
  $dirPath = Join-Path $root $subdir
  if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }

  foreach ($entry in (Get-ChildItem -LiteralPath $dirPath -Force -Recurse -File)) {
    if ($entry.Extension -ne '.txt' -and $entry.Extension -ne '.json') { continue }

    $rel = $entry.FullName.Substring($root.Length + 1).Replace('\', '/')

    # Skip anything under a hidden directory (.git and friends): the manifest
    # never lists those, and deleting through them would be wrong twice over.
    $hidden = $false
    foreach ($part in $rel -split '/') {
      if ($part.StartsWith('.')) { $hidden = $true; break }
    }
    if ($hidden) { continue }

    if ($seen.Contains($rel)) {
      $kept++
    } elseif ($PSCmdlet.ShouldProcess($rel, 'Delete')) {
      Remove-Item -LiteralPath $entry.FullName -Force
      Write-Output "deleted: $rel"
      $deleted++
    } else {
      # WhatIf: ShouldProcess said no, but the file is still an orphan.
      $deleted++
    }
  }
}

# ── empty directory report ────────────────────────────────────────────────

$emptyDirs = 0
if (-not $WhatIfPreference -and $deleted -gt 0) {
  foreach ($subdir in @('p', 'g')) {
    $dirPath = Join-Path $root $subdir
    if (-not (Test-Path -LiteralPath $dirPath -PathType Container)) { continue }
    foreach ($dir in (Get-ChildItem -LiteralPath $dirPath -Force -Recurse -Directory)) {
      if (-not (Get-ChildItem -LiteralPath $dir.FullName -Force)) {
        Write-Output "[empty] $($dir.FullName.Substring($root.Length + 1).Replace('\', '/'))"
        $emptyDirs++
      }
    }
  }
}

Write-Output ''
Write-Output '--- summary ---'
Write-Output "kept:   $kept"
Write-Output "deleted: $deleted"
Write-Output "empty dirs reported: $emptyDirs"

if ($WhatIfPreference) {
  Write-Output ''
  Write-Output '(Dry run complete — no files were removed.)'
}
