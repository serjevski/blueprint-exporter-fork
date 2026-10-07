# Rebuild Factorio blueprint books from the JSON files written by the
# blueprint-exporter mod.
#
# Walks the directory tree the mod creates, reads _book.json sidecars for book
# names, and reconstructs the full blueprint-book hierarchy. Output is a
# Factorio exchange string (0 + base64(zlib(json))) unless -Raw asks for the
# plain JSON.
#
# Payload bytes are never re-serialized. An exported .json already IS one
# Factorio item: its top-level key (blueprint, upgrade_planner, ...) is exactly
# the key the item needs. So the file text, minus the _export metadata, goes
# into the book as it stands. Running it through ConvertFrom-Json and
# ConvertTo-Json instead would rewrite every number -- 2.0 stores versions as
# uint64 and positions as doubles -- and it renders them differently on
# PowerShell 5.1 than on 7. json-to-string.ps1 follows the same rule for the
# same reason.
#
# Runs on Windows PowerShell 5.1 and PowerShell 7 alike: no -Encoding Byte
# (dropped in 7), no API that exists on only one of them.
#
# Parameters:
#   -In    One or more input directories (blueprint-exporter\p and/or g).
#          Several values go in a single argument separated by a comma;
#          repeating -In is refused by the binder on both PowerShell versions.
#   -Out   File to write. Without -Out the result goes to the clipboard.
#   -Raw   Emit uncompressed JSON instead of the compressed exchange string.
#
# Examples:
#   .\rebuild-books.ps1 -In "blueprint-exporter\p" -Out "rebuilt.txt"
#   .\rebuild-books.ps1 -In "blueprint-exporter\p","blueprint-exporter\g" -Out "all.txt"
#   .\rebuild-books.ps1 -In "blueprint-exporter\p" -Raw
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)][string[]]$In,
  [Parameter(Position = 1)][string]$Out,
  [switch]$Raw
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------------- helpers

# Read a .json file as UTF-8, strip a leading BOM if present, and return the
# raw text. The .NET call works on both PowerShell versions: -Encoding Byte was
# dropped in 7, and reading without it would apply the ANSI code page on 5.1,
# mangling every non-ASCII name.
function Read-JsonText([string]$Path) {
  $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Path))
  if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) {
    $text = $text.Substring(1)
  }
  return $text
}

# The .NET file APIs resolve a relative path against the process working
# directory, which does not follow Set-Location. Anchor to PowerShell's
# location instead so -In and -Out behave like any other command's path.
function Resolve-FullPath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }
  $base = (Get-Location -PSProvider FileSystem).ProviderPath
  return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $Path))
}

# Drop the _export metadata from an exported .json. It is written wherever it
# sits, so the leading comma is optional and the trailing comma is optional.
function Remove-ExportField([string]$Text) {
  $pattern = '(?s),?\s*"_export"\s*:\s*\{.*?\r?\n\s*\}(,)?'
  $stripped = [regex]::Replace($Text, $pattern, "").Trim()
  if ($stripped.Length -eq 0) {
    throw "nothing left after removing _export"
  }
  return $stripped
}

# Write a string as a JSON literal. Book labels are the only text this script
# produces itself; payload bytes are passed through untouched. Escapes are by
# code point so the comparison cannot depend on how PowerShell coerces char.
function ConvertTo-JsonStringLiteral([string]$Text) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if ($code -eq 34) { [void]$sb.Append('\"') }      # quotation mark
    elseif ($code -eq 92) { [void]$sb.Append('\\') }  # reverse solidus
    elseif ($code -eq 8) { [void]$sb.Append('\b') }
    elseif ($code -eq 12) { [void]$sb.Append('\f') }
    elseif ($code -eq 10) { [void]$sb.Append('\n') }
    elseif ($code -eq 13) { [void]$sb.Append('\r') }
    elseif ($code -eq 9) { [void]$sb.Append('\t') }
    elseif ($code -lt 32) { [void]$sb.Append('\u' + $code.ToString('x4')) }
    else { [void]$sb.Append([string]$ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# ------------------------------------------------------------------- Adler-32 & zlib

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

# ------------------------------------------------------------------- directory walker

# Walk a directory into a hashtable tree node.
# Keys: BookLabel (string|null, from _book.json), DirLabel (string|null, from
# the directory name), Texts (array of item JSON), Children (array of nodes).
function Read-DirTree($dirPath) {
  $node = @{
    BookLabel = $null
    DirLabel  = $null
    Texts     = @()
    Children  = @()
  }

  # _book.json carries no label for a book exported at the root, so the
  # directory name is the only name left. The mod prefixes it with the export
  # index (003_Blueprint book), which is not part of the label.
  #
  # -Force because the export directory is often made hidden by a VCS folder
  # beside it, and Get-Item without -Force fails on a hidden directory on 7.
  $leaf = (Get-Item -LiteralPath $dirPath -Force).Name
  if ($leaf) {
    $node.DirLabel = ($leaf -replace '^\d+_', '')
  }

  # Names hold square brackets, so every access stays literal.
  $entries = Get-ChildItem -LiteralPath $dirPath -Force | Sort-Object Name

  foreach ($entry in $entries) {
    $fullPath = $entry.FullName

    if ($entry.PSIsContainer) {
      # The export tree is a git repository, so .git sits right beside the book
      # directories. A book directory always starts with the export index, so a
      # leading dot can only be a tool directory -- and reading through a .git
      # object store would cost a lot for nothing.
      if ($entry.Name.StartsWith('.')) {
        continue
      }
      $child = Read-DirTree $fullPath
      if ($child.Texts.Count -gt 0 -or $child.Children.Count -gt 0 -or $child.BookLabel) {
        $node.Children += $child
      }
    } elseif ($entry.Name -eq '_book.json') {
      try {
        $bookData = (Read-JsonText $fullPath) | ConvertFrom-Json
        if ($bookData.PSObject.Properties['label']) {
          $node.BookLabel = $bookData.label
        }
      } catch {
        Write-Warning "Cannot parse $fullPath : $_"
      }
    } elseif ($entry.Name -match '\.json$') {
      # The export root keeps manifest.json beside the book directories.
      if ($entry.Name -like '_*' -or $entry.Name -eq 'manifest.json') {
        continue
      }
      try {
        $node.Texts += (Remove-ExportField (Read-JsonText $fullPath))
      } catch {
        Write-Warning "Cannot process $fullPath : $_"
      }
    }
  }

  return $node
}

# ------------------------------------------------------------------- tree to Factorio JSON

# The blueprint-exporter mod stores payloads verbatim: the file content IS one
# Factorio item (blueprint, upgrade_planner, etc.) with its top-level key.
# Factorio blueprint books, however, do NOT use an "items" array for their
# contents. They use "blueprints": [ { "blueprint": {...}, "index": 0 }, ... ].
# Each entry is keyed by the item type it represents, plus an "index" field.
# A nested book entry is keyed "blueprint_book" and carries the same
# blueprints/item/version structure recursively.
#
# This function emits the "blueprints" array.
function Get-Book-BlueprintsJson($node) {
  $parts = @()
  $index = 0

  foreach ($text in $node.Texts) {
    # $text is already the raw JSON for one item: {"blueprint":{...}} or
    # {"upgrade_planner":{...}}. We need to inject "index":N into it,
    # turning it into {"blueprint":{...},"index":N}.
    $parts += $text.Substring(0, $text.LastIndexOf('}')) + ',"index":' + $index + '}'
    $index++
  }

  foreach ($child in $node.Children) {
    $label = if ($child.BookLabel) {
      $child.BookLabel
    } elseif ($child.DirLabel) {
      $child.DirLabel
    } else {
      "Book"
    }
    $inner = '{"blueprints":' + (Get-Book-BlueprintsJson $child) +
      ',"item":"blueprint-book","label":' +
      (ConvertTo-JsonStringLiteral $label) +
      ',"active_index":0,"version":0}'
    $parts += '{"blueprint_book":' + $inner + ',"index":' + $index + '}'
    $index++
  }

  return '[' + ($parts -join ',') + ']'
}

# The root becomes the outer book. A root directory is a library shelf (p, g)
# rather than a book, so its name is not used as a label.
function Build-Book-Json($node) {
  $label = if ($node.BookLabel) { $node.BookLabel } else { "Rebuilt books" }
  return '{"blueprint_book":{"blueprints":' +
    (Get-Book-BlueprintsJson $node) +
    ',"item":"blueprint-book","label":' +
    (ConvertTo-JsonStringLiteral $label) +
    ',"active_index":0,"version":0}}'
}

# ------------------------------------------------------------------- encoding

function ConvertTo-ExchangeString([string]$Json) {
  $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
  return '0' + [System.Convert]::ToBase64String((Compress-Zlib $jsonBytes))
}

# ------------------------------------------------------------------- main

$mergedNode = @{
  BookLabel = $null
  DirLabel  = $null
  Texts     = @()
  Children  = @()
}

foreach ($inputDir in $In) {
  $absPath = Resolve-FullPath $inputDir
  if (-not (Test-Path -LiteralPath $absPath -PathType Container)) {
    Write-Error "directory not found: $absPath"
    exit 1
  }

  $tree = Read-DirTree $absPath
  $mergedNode.Texts += $tree.Texts
  $mergedNode.Children += $tree.Children
  # -In takes independent library roots. Should a root carry _book.json, the
  # first one with a label names the merged book.
  if (-not $mergedNode.BookLabel -and $tree.BookLabel) {
    $mergedNode.BookLabel = $tree.BookLabel
  }
}

if ($mergedNode.Texts.Count + $mergedNode.Children.Count -eq 0) {
  Write-Warning "no blueprints found under: $($In -join ', ')"
}

$bookJson = Build-Book-Json $mergedNode

if ($Raw) {
  $output = $bookJson
} else {
  $output = ConvertTo-ExchangeString $bookJson
}

if ($Out) {
  $outPath = Resolve-FullPath $Out
  [System.IO.File]::WriteAllText($outPath, $output + "`n",
    (New-Object System.Text.UTF8Encoding $false))
  Write-Output "Written $outPath"
} else {
  Set-Clipboard -Value $output
  Write-Output "Copied to clipboard"
}
