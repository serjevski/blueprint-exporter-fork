<#
.SYNOPSIS
  Turn the exported .json files back into Factorio blueprint strings.

.DESCRIPTION
  The mod writes two files per blueprint: a .txt with the exchange string and a
  .json with the same payload, pretty printed for git. This script rebuilds an
  importable string from the .json, so an edited .json can go back into the game.

  The payload is never re-serialized. The bytes of the file are what get
  compressed, which keeps numbers exactly as Factorio wrote them: ConvertTo-Json
  in PowerShell 5.1 renders doubles with the current culture ("0,5" under a
  Russian locale), which would produce JSON the game cannot read.

  The _export field (the label with its markup, plus the chain of book names)
  is dropped: it is export metadata, not blueprint data. _book.json sidecars
  are skipped for the same reason.

  Output is the classic form "0" + base64(zlib(json)), which every supported
  Factorio accepts. -Raw prints the plain JSON instead; 2.0 and newer also
  accept that, and it needs no compression at all.

.PARAMETER In
  A .json file, or a directory that is searched recursively.

.PARAMETER Out
  File to write when In is one file. Directory to mirror into when In is many
  files. Without -Out a single file is printed to stdout, and more than one is
  an error so nothing is silently dropped.

.PARAMETER Raw
  Emit uncompressed JSON instead of the compressed string.

.PARAMETER NoValidate
  Skip the parse check. The check only proves the input is well formed JSON; it
  does not change the bytes that are written.

.EXAMPLE
  .\json-to-string.ps1 .\009_Roboport.json | Set-Clipboard

.EXAMPLE
  .\json-to-string.ps1 . -Out ..\rebuilt
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string]$In,
  [Parameter(Position = 1)][string]$Out,
  [switch]$Raw,
  [switch]$NoValidate
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

function Read-JsonText([string]$Path) {
  # Get-Content without -Encoding Byte would apply the ANSI code page on a
  # PowerShell 5.1 that has no BOM to read, mangling every non-ASCII name.
  $bytes = Get-Content -LiteralPath $Path -Encoding Byte -ReadCount 0
  $text = [System.Text.Encoding]::UTF8.GetString($bytes)
  # Strip a leading UTF-8 BOM if present (0xEF 0xBB 0xBF → U+FEFF)
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
    $text = $text.Substring(1)
  }
  return $text
}

function Remove-ExportField([string]$Text) {
  # _export may appear at any position (it is added after the Factorio payload,
  # so it lands last, but a converter reading a pre-0.5 file might find it first).
  $pattern = '(?s),?\s*"_export"\s*:\s*\{.*?\r?\n\s*\}(,)?'
  $stripped = [regex]::Replace($Text, $pattern, "")
  return $stripped.Trim()
}

function Test-Json([string]$Text) {
  # JavaScriptSerializer, not ConvertFrom-Json: the cmdlet in 5.1 is slower on
  # big payloads. Its default length cap is 2 MB and a real library holds
  # circuit books of 3 to 6.7 MB, which are perfectly valid -- the cap has to go
  # up or those files look corrupt. Each setting is guarded on its own: an
  # assignment that throws must not make a valid file fail the check.
  try {
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    try { $serializer.MaxJsonLength = [int]::MaxValue } catch { }
    # MaxDepth is not a settable property on every .NET build. The default is
    # 100 and the deepest blueprint in a real 637-record library nests 13
    # levels, so it is left alone.
    $null = $serializer.DeserializeObject($Text)
    return $true
  } catch {
    return $false
  }
}

function Get-Adler32([byte[]]$Data) {
  $a = 1; $b = 0
  foreach ($byte in $Data) {
    $a = ($a + $byte) % 65521
    $b = ($b + $a) % 65521
  }
  return @([byte](($b -shr 8) -band 0xFF), [byte]($b -band 0xFF),
          [byte](($a -shr 8) -band 0xFF), [byte]($a -band 0xFF))
}

function Compress-Zlib([byte[]]$Data) {
  # DeflateStream writes raw DEFLATE. Factorio expects zlib: two header bytes,
  # the same DEFLATE stream, then Adler-32 of the uncompressed data.
  $memory = New-Object System.IO.MemoryStream
  $deflater = New-Object System.IO.Compression.DeflateStream(
    $memory, [System.IO.Compression.CompressionMode]::Compress, $true)
  $deflater.Write($Data, 0, $Data.Length)
  $deflater.Dispose()
  $deflated = $memory.ToArray()
  $memory.Dispose()

  $zlib = New-Object System.IO.MemoryStream
  $zlib.WriteByte(0x78)
  $zlib.WriteByte(0x9C)
  $zlib.Write($deflated, 0, $deflated.Length)
  $tail = Get-Adler32 $Data
  $zlib.Write($tail, 0, $tail.Length)
  $out = $zlib.ToArray()
  $zlib.Dispose()
  return $out
}

function Get-Files([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    return Get-Item -LiteralPath $Path
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "no such file or directory: $Path"
  }
  # Square brackets appear in exported names, so every path access has to stay
  # literal; -Filter is safe because it matches names, not paths.
  Get-ChildItem -LiteralPath $Path -Recurse -Filter "*.json" -File |
    Where-Object { $_.Name -notlike "_*" -and $_.Name -ne "manifest.json" }
  # Nothing is wrapped in an array on purpose. The caller collects with @(),
  # which always yields something with .Count, even for a single blueprint.
  # Returning ",@(...)" here would hand that caller an array nested inside an
  # array, and the loop below would then receive the whole list as one "file".
}

function Convert-One($File, [string]$Root) {
  $text = Remove-ExportField (Read-JsonText $File.FullName)
  if ($text.Length -eq 0) {
    throw "nothing left after removing _export: $($File.FullName)"
  }
  if (-not $NoValidate -and -not (Test-Json $text)) {
    throw "not valid JSON: $($File.FullName)"
  }
  if ($Raw) {
    return $text
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  return "0" + [System.Convert]::ToBase64String((Compress-Zlib $bytes))
}

function Get-RelativePath([string]$Root, [string]$Full) {
  $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
  if ($Full.Length -le $rootFull.Length -or
      $Full.Substring(0, $rootFull.Length) -ne $rootFull) {
    return Split-Path -Leaf $Full
  }
  return $Full.Substring($rootFull.Length + 1).TrimStart('\', '/')
}

$files = @(Get-Files $In)
if ($files.Count -eq 0) {
  Write-Error "no .json files found under $In"
  exit 1
}

$failed = 0
if ($files.Count -eq 1 -and -not $Out) {
  # Clipboard case: the string alone, nothing else on stdout.
  Write-Output (Convert-One $files[0] $In)
  exit 0
}

if ($files.Count -gt 1 -and -not $Out) {
  Write-Error "$($files.Count) files: give -Out <directory> (or a single file to get stdout)"
  exit 1
}

$outIsDir = (Test-Path -LiteralPath $Out -PathType Container) -or
            ($Out -match '[\\/]$') -or $files.Count -gt 1
if ($outIsDir) {
  if (-not (Test-Path -LiteralPath $Out)) {
    New-Item -ItemType Directory -Path $Out | Out-Null
  }
}

foreach ($file in $files) {
  try {
    $result = Convert-One $file $In
  } catch {
    Write-Warning ("failed: " + $_.Exception.Message)
    $failed++
    continue
  }
  if ($outIsDir) {
    $rel = Get-RelativePath $In $file.FullName
    $targetRel = if ($Raw) { $rel } else { [System.IO.Path]::ChangeExtension($rel, ".txt") }
    $target = Join-Path $Out $targetRel
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($target, $result,
      (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ("wrote " + $targetRel)
  } elseif ($files.Count -eq 1) {
    [System.IO.File]::WriteAllText($Out, $result,
      (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ("wrote " + $Out)
  }
}

if ($failed -gt 0) {
  Write-Error "$failed of $($files.Count) files failed"
  exit 1
}
