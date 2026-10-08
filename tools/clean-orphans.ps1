# Delete blueprint files under the book roots that manifest.json does not list,
# then remove the folders that are left without contents.
#
# The mod writes manifest.json with the list of every file it produced.  A
# blueprint deleted in game leaves its files behind: the next export neither
# writes nor removes them (Factorio Lua cannot delete files), and the folder
# that held them stays behind empty for the same reason.  This script removes
# exactly those orphans and exactly those empty folders.
#
# Usage:
#   .\clean-orphans.ps1 <exportFolder>
#   .\clean-orphans.ps1 <exportFolder> -WhatIf
#
#   -WhatIf   only report what would be deleted, remove nothing
#
# Three things are never touched: anything under a hidden directory (.git and
# friends, which belongs to the version control of the folder rather than to the
# mod), the book roots themselves (an empty p/ or g/ is part of the export
# layout, not the trace of a deleted book), and any file whose name JSON cannot
# spell - such a file is reported instead, because an absent list entry proves
# nothing about a name the list could never carry.
#
# Runs on PowerShell 5.1 and 7 alike.

[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$Root
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

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

# Read the file as UTF-8.  -Encoding Byte was dropped in PS 7, and reading
# without it applies the ANSI code page on 5.1 and mangles every non-ASCII name.
function Read-JsonText([string]$Path) {
  return [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
}

$root = (Resolve-FullPath $Root).TrimEnd('\', '/')
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

# Ordinal comparison: the manifest holds the exact names the export wrote, and
# forward slashes are the form it uses.
$listed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in @($filesProp.Value)) { [void]$listed.Add([string]$name) }

# A name JSON has to escape cannot appear in manifest.json at all, so its
# absence from the list proves nothing about the file.
function Test-UnspellableName([string]$Name) {
  foreach ($char in $Name.ToCharArray()) {
    if ([int][char]$char -lt 0x20 -or $char -eq '"' -or $char -eq '\') { return $true }
  }
  return $false
}

# The manifest knows which folders hold the books; p and g are only the fallback
# for a manifest written before those were recorded.
$bookRoots = @()
$rootsProp = $manifest.PSObject.Properties['roots']
if ($null -ne $rootsProp -and $null -ne $rootsProp.Value) {
  foreach ($key in $rootsProp.Value.PSObject.Properties.Name) {
    $bookRoots += [string]$rootsProp.Value.$key
  }
}
if ($bookRoots.Count -eq 0) { $bookRoots = @('p', 'g') }
$bookRoots = @($bookRoots | Where-Object { $_ -notmatch '(^|/)\.' } | Select-Object -Unique)

# Saying nothing at all is the worst failure this script can have: a folder that
# holds none of the book folders is a wrong folder, not a clean one.
$foundRoots = @($bookRoots | Where-Object { Test-Path -LiteralPath (Join-Path $root $_) -PathType Container })
if ($foundRoots.Count -eq 0) {
  throw ("no book folder among ({0}) in {1}: this does not look like an export folder" -f ($bookRoots -join ', '), $root)
}

# Relative to the export folder, in the form the manifest uses.
function Get-RelativePath([string]$Path) {
  return $Path.Substring($root.Length + 1).Replace('\', '/')
}

# Only the book folders are cleaned.  Anything under a hidden directory belongs
# to the version control of the export folder, and without this guard every
# object of the git history would read as an orphan.
function Test-CleanablePath([string]$Relative) {
  return ($Relative -notmatch '(^|/)\.')
}

$kept = 0
$deleted = 0
$scanned = 0
$skipped = 0
$emptyDirs = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'

foreach ($subdir in $foundRoots) {
  $dirPath = Join-Path $root $subdir

  # Every folder is collected before any file is deleted, so that a folder which
  # holds nothing but other folders is judged once its children are gone.  One
  # unreadable folder must not stop the run, hence SilentlyContinue.
  foreach ($dir in (Get-ChildItem -LiteralPath $dirPath -Force -Recurse -Directory -ErrorAction SilentlyContinue)) {
    if (Test-CleanablePath (Get-RelativePath $dir.FullName)) { $emptyDirs.Add($dir) }
  }

  foreach ($entry in (Get-ChildItem -LiteralPath $dirPath -Force -Recurse -File -ErrorAction SilentlyContinue)) {
    # .backup is written next to a .json by json-to-string and disappears from
    # the manifest as soon as the book is deleted, just like the .json.
    if ($entry.Extension -ne '.txt' -and $entry.Extension -ne '.json' -and $entry.Extension -ne '.backup') { continue }

    $relative = Get-RelativePath $entry.FullName
    if (-not (Test-CleanablePath $relative)) { continue }

    $scanned++
    if ($listed.Contains($relative)) {
      $kept++
    } elseif (Test-UnspellableName $entry.Name) {
      Write-Warning "not listed, but manifest.json could not name it either: $relative"
      $skipped++
    } elseif ($PSCmdlet.ShouldProcess($relative, 'Delete')) {
      Remove-Item -LiteralPath $entry.FullName -Force
      Write-Output "deleted: $relative"
      $deleted++
    } else {
      # WhatIf: ShouldProcess said no, but the file is an orphan all the same.
      $deleted++
    }
  }
}

if ($scanned -eq 0) {
  Write-Warning ("no .txt/.json/.backup files under ({0}) in {1}: nothing to clean" -f ($foundRoots -join ', '), $root)
}

# ── folders left without contents ─────────────────────────────────────────
#
# Deleting a book in game removes its files from the manifest, but the folder
# they lived in survives: Factorio Lua cannot delete a directory.  The deepest
# folders go first, so a folder that only held a folder already removed is met
# empty in the same pass, and the pass walks up until it reaches a book root,
# which is part of the export layout and always stays.

$removedDirs = 0
foreach ($dir in ($emptyDirs | Sort-Object { $_.FullName.Length } -Descending)) {
  $current = $dir
  while ($null -ne $current) {
    $relative = Get-RelativePath $current.FullName
    if ($relative.IndexOf('/') -lt 0) { break }
    # The list holds every folder the run collected, and a deeper folder has
    # already pruned its parents on the way up, so meeting one that is gone is
    # normal.  Without this check Remove-Item meets a vanished path and, under
    # ErrorActionPreference Stop, takes the whole run down with it: no summary,
    # no further folders.
    if (-not (Test-Path -LiteralPath $current.FullName -PathType Container)) { break }
    if (@(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }

    if ($PSCmdlet.ShouldProcess($relative, 'Remove folder')) {
      Remove-Item -LiteralPath $current.FullName -Force
      Write-Output "pruned: $relative"
    }
    $removedDirs++

    # Under WhatIf nothing was really removed, so the parent is not empty yet
    # and the report would claim folders the run cannot delete.
    if ($WhatIfPreference) { break }
    $current = $current.Parent
  }
}

Write-Output ''
Write-Output '--- summary ---'
Write-Output "kept:    $kept"
Write-Output "deleted: $deleted"
if ($WhatIfPreference) {
  Write-Output "empty folders to remove: $removedDirs"
} else {
  Write-Output "empty folders removed: $removedDirs"
}
if ($skipped) { Write-Output "unspellable, left alone: $skipped (see the warnings above)" }

if ($kept + $deleted + $removedDirs -eq 0) {
  Write-Output ''
  Write-Output 'Nothing the manifest does not list was found, and no folder was empty.'
}

if ($WhatIfPreference) {
  Write-Output ''
  Write-Output '(Dry run: nothing was removed. Run again without -WhatIf to delete.)'
}
