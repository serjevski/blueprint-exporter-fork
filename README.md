# Blueprint Exporter

Factorio 2.1 mod that exports your entire blueprint library to files, so you can keep it in git.

## Usage

1. Install the mod and click the **Export blueprint library** button on the shortcut bar.
2. The export lands in `script-output/blueprint-exporter/`: books become directories. Each blueprint/planner produces two files — `.txt` with the exchange string, and `.json` with the full blueprint data (keys lowercased, alphabetically sorted). Both "My blueprints" and "Game blueprints" are included. Large libraries are processed a few records per tick, so the game stays responsive.
3. (Optional) Run `backup.ps1` to mirror the export into this repo's `blueprints/` folder and create a git commit. Deleted blueprints are removed from the mirror automatically.

## What the export looks like

```text
blueprint-exporter/
  manifest.json             everything written, with a format version
  p/                        "My blueprints"  (g/ = "Game blueprints")
    001_Roboport.txt        the exchange string, what the game imports
    001_Roboport.json       the same payload, decoded and pretty printed
    007_Circuits/
      _book.json            the book's real name, see below
      001_All my Circuits.txt
      001_All my Circuits.json
  tools/                    converters, rewritten on every export
```

File and directory names are `<index>_<label>`. The index keeps two blueprints with
the same name apart; markup (`[item=steel-plate]`, `[/color]`, ...) is stripped,
because it would otherwise be half of every path. The label the game actually shows
is kept in the export instead:

- `_export.label` in a blueprint's `.json`, and `_export.book_path` with the
  original names of the books it sits in, outermost first;
- `_book.json` in a book's directory — a book has no file of its own, so this is the
  only place its name survives. An empty book gets one too.

Keys in `.json` are lowercased and sorted so diffs stay readable. That is lossy for
data the game does not name itself: mod data under `tags` can be case-sensitive, so
**the `.txt` stays the authoritative copy** and the `.json` is the readable one.

Paths are kept under 140 UTF-16 units so Windows does not refuse them; a directory
shares what is left with everything under it, so deep book nesting cannot overflow
it.

## Turning an edited .json back into a blueprint

Both converters are written into `tools/` at the end of every export — they travel
inside the mod, because Factorio's Lua cannot read a file at runtime. They rebuild an
importable string from a `.json`; paste the result into the in-game blueprint string
box.

```powershell
# PowerShell 5.1+, one file to the clipboard
./tools/json-to-string.ps1 ./001_Roboport.json | Set-Clipboard

# a whole tree, mirrored into a directory of .txt
./tools/json-to-string.ps1 ./blueprint-exporter -Out ./rebuilt
```

```bash
# bash, needs gzip, base64 and (for validation) python3
./tools/json-to-string.sh 001_Roboport.json | xclip -selection clipboard
./tools/json-to-string.sh blueprint-exporter rebuilt
```

Both skip `_book.json` and `manifest.json`, drop `_export`, and never re-serialize
the payload — the bytes of the file are what get compressed, so every number survives
exactly. `-Raw` / `--raw` prints plain JSON instead of the compressed string, which
Factorio 2.0 and newer accept for import as well.

## Testing

```text
node .dev-test/run.js                 Lua suite under fengari, no game needed
node .dev-test/check_converters.js    builds a fixture with the real export code and
                                      drives both converters through it
node .dev-test/check_real_export.js <export dir>
                                      re-derives every name from a real export
```

`node .dev-test/embed_tools.js` refreshes the copy of the converters that the mod
ships; run it after editing either script, and the suite fails if you forget.

## Build

`publish.bat` creates `publish/blueprint-exporter_<version>.zip` ready for the mod portal.
