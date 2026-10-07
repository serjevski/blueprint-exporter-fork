#!/usr/bin/env bash
#
# Turn the exported .json files back into Factorio blueprint strings.
#
# The mod writes two files per blueprint: a .txt with the exchange string and a
# .json with the same payload, pretty printed for git. This script rebuilds an
# importable string from the .json, so an edited .json can go back into the game.
#
# The payload is never re-serialized -- the bytes of the file are what get
# compressed, which keeps every number exactly as Factorio wrote it.
#
# The _export field (label with its markup, plus the chain of book names) is
# dropped, and _book.json sidecars are skipped: both are export metadata, not
# blueprint data.
#
# Usage: json-to-string.sh [options] IN [OUT]
#   IN   a .json file, or a directory searched recursively
#   OUT  file to write for a single IN, directory to mirror into for many
#
# Options:
#   --raw           emit plain JSON instead of "0"+base64(zlib(json))
#   --no-validate   skip the parse check (needs python3; it changes no bytes)
#
# With one input file and no OUT the string goes to stdout, so
#   ./json-to-string.sh 009_Roboport.json | xclip -selection clipboard
# works as expected.

set -euo pipefail

raw=0
validate=1

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

raw_json() {
  # Drop the "_export" block wherever it sits: first in files written before
  # 0.5.0, last in the current layout. One line of lookahead is enough -- when
  # the block is last, the comma on the line before it would dangle, so it is
  # stripped from the buffered line before that line is printed.
  awk '
    BEGIN { state = 0; pending = "" }
    state == 0 && $0 ~ /"_export"[ 	]*:/ {
      if (pending != "") { sub(/,[ 	]*$/, "", pending); print pending }
      pending = ""
      state = 1
      next
    }
    state == 1 {
      if ($0 ~ /^[ 	]*\},?[ 	]*$/) state = 0
      next
    }
    {
      if (pending != "") print pending
      pending = $0
    }
    END { if (pending != "") print pending }
  ' "$1"
}

adler32_octal() {
  # zlib closes its stream with Adler-32 of the uncompressed data. Only POSIX
  # awk here: no strtonum(), no and(), no rshift() -- mawk and busybox have
  # none of them.
  od -An -v -tx1 "$1" | tr -s ' \t\n' ' ' | awk '
    BEGIN { a = 1; b = 0 }   # Adler-32 accumulates from 1, not from 0
    function hexval(c) {
      if (c >= "0" && c <= "9") return c + 0
      return index("abcdef", c) + 9
    }
    {
      for (i = 1; i <= NF; i++) {
        v = hexval(substr($i, 1, 1)) * 16 + hexval(substr($i, 2, 1))
        a = (a + v) % 65521
        b = (b + a) % 65521
      }
    }
    END {
      n = (b * 65536 + a) % 4294967296
      for (s = 3; s >= 0; s--) printf "\\%03o", int(n / (256 ^ s)) % 256
    }
  ' | tr -d "\n"
}

to_string() {
  local file="$1"
  # The leading "0" is the format version byte Factorio puts in front of the
  # base64; without it the game reads the string as corrupt.
  printf '0'
  # gzip stores the name and mtime only with -n; without it the 10-byte header
  # would hold them and the slice below would cut into the DEFLATE stream.
  # head -c -8 drops the CRC32 and ISIZE that gzip appends but zlib does not use.
  {
    printf '%b' '\170\234'
    gzip -n -9 -c "$file" | tail -c +11 | head -c -8
    printf '%b' "$(adler32_octal "$file")"
  } | base64 -w0
}

collect() {
  local target="$1"
  if [ -f "$target" ]; then
    printf '%s\n' "$target"
  elif [ -d "$target" ]; then
    find "$target" -type f -name '*.json' \
      ! -name '_*' ! -name 'manifest.json' | LC_ALL=C sort
  else
    die "no such file or directory: $target"
  fi
}

relative() {
  local root="$1" full="$2"
  local prefix="${root%/}/"
  case "$full" in
    "$prefix"*) printf '%s\n' "${full#"$prefix"}" ;;
    *)          basename "$full" ;;
  esac
}

# Options may appear before or after the paths. A loop that stopped at the
# first non-option would silently ignore --raw in "script.sh IN OUT --raw" and
# write compressed output into a directory the user asked to be plain JSON.
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) raw=1 ;;
    --no-validate) validate=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) positional+=("$1") ;;
  esac
  shift
done

[ ${#positional[@]} -ge 1 ] || { usage >&2; die "an input path is required"; }
in_path="${positional[0]}"
out_path="${positional[1]:-}"

mapfile -t files < <(collect "$in_path")
[ "${#files[@]}" -gt 0 ] || die "no .json files found under $in_path"

tmp=""
cleanup() { [ -n "$tmp" ] && rm -f "$tmp"; }
trap cleanup EXIT

process() {
  # Write the payload to a real file: python3 wants a path, and the compressor
  # reads from a file anyway.
  local src="$1" dest="$2"
  raw_json "$src" > "$tmp"
  if [ "$validate" -eq 1 ]; then
    if command -v python3 >/dev/null 2>&1; then
      python3 -c 'import json,sys
with open(sys.argv[1], encoding="utf-8") as fh: json.load(fh)' "$tmp" \
        || { printf 'error: not valid JSON: %s\n' "$src" >&2; return 1; }
    else
      printf 'note: python3 is missing, the JSON was not validated\n' >&2
      validate=0
    fi
  fi
  if [ "$raw" -eq 1 ]; then
    cat "$tmp" > "$dest"
  else
    to_string "$tmp" > "$dest"
  fi
}

if [ "${#files[@]}" -eq 1 ] && [ -z "$out_path" ]; then
  tmp="$(mktemp)"
  process "${files[0]}" /dev/stdout
  exit 0
fi

[ -n "$out_path" ] || die "${#files[@]} files: give OUT (a directory) to write them"

tmp="$(mktemp)"
failed=0
count=0
for file in "${files[@]}"; do
  if [ "${#files[@]}" -eq 1 ]; then
    dest="$out_path"
    mkdir -p "$(dirname "$dest")"
  else
    rel="$(relative "$in_path" "$file")"
    if [ "$raw" -eq 1 ]; then
      dest="$out_path/$rel"
    else
      dest="$out_path/${rel%.json}.txt"
    fi
    mkdir -p "$(dirname "$dest")"
  fi
  if process "$file" "$dest"; then
    printf 'wrote %s\n' "$dest"
    count=$((count + 1))
  else
    printf 'failed: %s\n' "$file" >&2
    failed=$((failed + 1))
  fi
done

if [ "$failed" -gt 0 ]; then
  die "$failed of $((count + failed)) files failed"
fi
