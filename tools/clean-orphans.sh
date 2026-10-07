#!/usr/bin/env bash
#
# Delete blueprint files under p/ and g/ that are not listed in manifest.json.
#
# The mod writes manifest.json with the list of every file it produced.  A
# blueprint deleted in game leaves its .txt/.json behind: the next export
# neither writes nor removes them (Factorio Lua cannot delete files).  This
# script removes exactly those orphans.
#
# Usage:
#   ./clean-orphans.sh <directory> [--dry-run]
#
# Examples:
#   ./clean-orphans.sh /path/to/blueprint-exporter
#   ./clean-orphans.sh . --dry-run
#
# Only bash and coreutils: no python, no GNU-only awk extensions.

set -euo pipefail

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

# ── args ────────────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

if [[ $1 == "-h" || $1 == "--help" ]]; then
  usage
  exit 0
fi

TARGET_DIR=$(cd "$1" 2>/dev/null && pwd) || {
  echo "FATAL: cannot enter '$1'" >&2
  exit 1
}

DRY_RUN=false
shift
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    *) echo "FATAL: unknown option '$arg'" >&2; usage >&2; exit 1 ;;
  esac
done

# ── manifest ────────────────────────────────────────────────────────────

MANIFEST="$TARGET_DIR/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "FATAL: no manifest.json in '$TARGET_DIR'" >&2
  exit 1
fi

# Parse the "files" array from manifest.json using POSIX awk.
# The manifest is written by helpers.table_to_json as a single line, but the
# parser joins all input lines so a pretty-printed copy works too.
#
# Only POSIX awk: no strtonum(), gensub(), or character classes like [[:space:]]
# in dynamic regexes -- mawk and busybox awk implement none of them.
manifest_paths() {
  awk '
    { lines[NR] = $0 }
    END {
      text = ""
      for (i = 1; i <= NR; i++) text = text lines[i] "\n"

      p = index(text, "\"files\"")
      if (p == 0) { print "manifest: no files array" > "/dev/stderr"; exit 1 }

      # Find the opening bracket right after "files"
      rest = substr(text, p)
      b = index(rest, "[")
      if (b == 0) { print "manifest: malformed files array" > "/dev/stderr"; exit 1 }

      # Walk the array, extracting strings.
      i = p + b   # just past the opening bracket
      n = length(text)
      count = 0
      while (i <= n) {
        c = substr(text, i, 1)
        if (c == "]") {
          if (count == 0) {
            print "manifest: files array is empty" > "/dev/stderr"
          }
          exit 0
        }
        if (c == "{") {
          print "manifest: object entries not supported" > "/dev/stderr"
          exit 1
        }
        if (c != "\"") { i++; continue }

        # Start of a quoted string
        i++
        s = ""
        while (i <= n) {
          c = substr(text, i, 1)
          if (c == "\\") {
            nc = substr(text, i + 1, 1)
            if (nc == "n") s = s "\n"
            else if (nc == "t") s = s "\t"
            else if (nc == "r") s = s "\r"
            else                s = s nc
            i += 2
            continue
          }
          if (c == "\"") { i++; break }
          s = s c
          i++
        }
        print s
        count++
      }
      # Reached the end without a closing bracket
      print "manifest: unterminated files array" > "/dev/stderr"
      exit 1
    }
  ' "$MANIFEST"
}

mapfile -t MANIFEST_FILES < <(manifest_paths "$MANIFEST")

# Build an associative array for O(1) lookup.
declare -A KEEP_SET=()
for f in "${MANIFEST_FILES[@]}"; do
  KEEP_SET["$f"]=1
done

# ── scan and delete ─────────────────────────────────────────────────────

KEEP_COUNT=0
DELETE_COUNT=0
EMPTY_DIR_COUNT=0

# Only scan p/ and g/ — the blueprint libraries.  Prune hidden directories
# (e.g. .git) — the mod never writes there.
for subdir in p g; do
  [[ -d "$TARGET_DIR/$subdir" ]] || continue

  mapfile -d '' -t SUBDIR_FILES < <(
    find "$TARGET_DIR/$subdir" -mindepth 1 \( -name '.*' -prune \) -o \( -type f -print0 \)
  )

  for abs_path in "${SUBDIR_FILES[@]}"; do
    # Relative path from TARGET_DIR (strip the leading "TARGET_DIR/" part).
    rel_path="${abs_path#"$TARGET_DIR"/}"

    # Only .txt and .json.
    case "$rel_path" in
      *.txt|*.json) ;;
      *) continue ;;
    esac

    if [[ -n "${KEEP_SET[$rel_path]+x}" ]]; then
      (( ++KEEP_COUNT )) || true
    else
      (( ++DELETE_COUNT )) || true
      if $DRY_RUN; then
        echo "DRY-RUN: would delete $rel_path"
      else
        rm -f -- "$abs_path"
        echo "deleted: $rel_path"
      fi
    fi
  done
done

# ── empty directory report ─────────────────────────────────────────────

if ! $DRY_RUN && [[ $DELETE_COUNT -gt 0 ]]; then
  # Report directories that became empty after orphan removal.
  # Informational only -- the script never deletes a directory, and the
  # next export recreates whatever it needs.
  while IFS= read -r -d '' dir; do
    rel_dir="${dir#"$TARGET_DIR"/}"
    echo "[empty] $rel_dir"
    (( ++EMPTY_DIR_COUNT )) || true
  done < <(find "$TARGET_DIR" -mindepth 1 -type d -empty -print0 2>/dev/null)
fi

# ── summary ─────────────────────────────────────────────────────────────

echo ""
echo "--- summary ---"
echo "kept:   $KEEP_COUNT"
echo "deleted: $DELETE_COUNT"
echo "empty dirs reported: $EMPTY_DIR_COUNT"
if $DRY_RUN; then
  echo ""
  echo "(Dry run complete — no files were removed.)"
fi
