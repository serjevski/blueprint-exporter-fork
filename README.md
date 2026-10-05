# Blueprint Exporter

Factorio 2.1 mod that exports your entire blueprint library to files, so you can keep it in git.

## Usage

1. Install the mod and click the **Export blueprint library** button on the shortcut bar.
2. The export lands in `script-output/blueprint-exporter/`: books become directories, each blueprint/planner becomes a `.txt` file with its exchange string. Both "My blueprints" and "Game blueprints" are included. Large libraries are processed a few records per tick, so the game stays responsive.
3. (Optional) Run `backup.ps1` to mirror the export into this repo's `blueprints/` folder and create a git commit. Deleted blueprints are removed from the mirror automatically.

## Build

`publish.bat` creates `publish/blueprint-exporter_<version>.zip` ready for the mod portal.
