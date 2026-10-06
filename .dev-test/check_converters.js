"use strict";
/*
 * Round-trip check for the shipped converters.
 *
 *   node .dev-test/check_converters.js
 *
 * The fixture is produced by the real export code (scripts/export.lua under
 * fengari), not hand-written, so the converters are tested against the exact
 * bytes the mod writes -- including _export, _book.json sidecars, markup in
 * labels and deep book nesting. The real library on disk predates _export, so
 * this is the only place that field gets exercised.
 *
 * Each converter must reproduce, from a .json, a string that inflates back to
 * that same .json with _export removed. Sidecars and the manifest must not turn
 * into blueprints, and PowerShell and bash must agree with each other.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { spawnSync } = require("child_process");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const root = path.resolve(__dirname, "..");
const tmp = path.join(__dirname, "tmp");
const fixture = path.join(tmp, "fixture");
const outPs = path.join(tmp, "out-ps");
const outSh = path.join(tmp, "out-sh");
const rawPs = path.join(tmp, "raw-ps");
const rawSh = path.join(tmp, "raw-sh");

let failures = 0;
function check(name, ok, detail) {
  if (!ok) {
    failures++;
    console.log("FAIL " + name + (detail ? "\n      " + String(detail).split("\n")[0] : ""));
  } else {
    console.log("ok   " + name);
  }
}

function rmrf(p) {
  if (fs.existsSync(p)) fs.rmSync(p, { recursive: true, force: true });
}
function toWsl(p) {
  const abs = path.resolve(p).replace(/\\/g, "/");
  return "/mnt/" + abs[0].toLowerCase() + abs.slice(2);
}

// --------------------------------------------------------------- build fixture
const FIXTURE_LUA = `
local Json = require("scripts.json")
local Export = require("scripts.export")

local writes, printed, current_player
helpers = {
  write_file = function(path, content) writes[path] = content end,
  decode_string = function(text) return text end,
  json_to_table = Json.decode,
  table_to_json = function(t)
    local function esc(s) return '"' .. s:gsub('"', '\\\\"') .. '"' end
    local function enc(v)
      local kind = type(v)
      if kind == "string" then return esc(v) end
      if kind ~= "table" then return tostring(v) end
      local parts = {}
      if #v > 0 then
        for i = 1, #v do parts[#parts + 1] = enc(v[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
      end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = esc(tostring(k)) .. ":" .. enc(v[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    return enc(t)
  end,
}
game = { tick = 4242, blueprints = {}, get_player = function() return current_player end }
storage = {}

local function record(label, payload, rtype, contents)
  return {
    valid = true, type = rtype or "blueprint", label = label,
    contents = contents or {},
    export_record = function(self) return "0" .. payload end,
  }
end

-- Doubles that need 17 digits, a null, and a mixed-case key: exactly the
-- things the .json used to get wrong.
local payload = [[{"blueprint":{"item":"steel-chest","label":"Roboport","entities":[{"entity_number":1,"name":"steel-chest","position":[0.5,-1.25],"color":[0.49803921580314636,0.7745016813278198,0.7532740831375122,0.30371421575546265],"inventory":null,"tags":{"QuickbarTemplates":{"A":1}}}]}}]]

local deep = record("Deep " .. string.rep("x", 200), payload)
local player_bp = {
  record("[item=steel-plate] Roboport", payload),
  record("018_Multi-prov trah stn", payload),
  record("", payload, "blueprint-book", {
    record("[fluid=water] Book inside a book", payload, "blueprint-book", {
      record("Nested leaf", payload),
      deep,
    }),
    record("Empty book", payload, "blueprint-book", {}),
    record("[virtual-signal=signal-item-parameter] 1-1-0", payload),
  }),
  record(string.char(0xF0, 0x9F, 0x96, 0xA9) .. " Chest", payload),
}
local game_bp = { record("[item=express-transport-belt] Global belt", payload) }

writes, printed = {}, {}
game.blueprints = game_bp
current_player = {
  index = 1, connected = true, force = { index = 1 }, blueprints = player_bp,
  print = function(msg) printed[#printed + 1] = msg end,
}
Export.start(current_player)
local guard = 0
while storage.job and guard < 200 do Export.process() guard = guard + 1 end

FIXTURE_OUT = Json.encode(writes)

-- Keyed by path: Json.encode writes a hand-built integer-keyed table as an
-- object with "1"/"2" keys, not an array, so an array shape here would be a lie.
local by_path = {}
for _, tool in ipairs(require("scripts.tools")) do by_path[tool.path] = tool.text end
TOOLS_OUT = Json.encode(by_path)
`;

function buildFixture() {
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  lua.lua_getglobal(L, to_luastring("package"));
  lua.lua_pushstring(L, to_luastring([path.join(root, "?.lua")].join(";")));
  lua.lua_setfield(L, -2, to_luastring("path"));
  lua.lua_pop(L, 1);
  const code = to_luastring(FIXTURE_LUA);
  if (lauxlib.luaL_loadstring(L, code) !== lua.LUA_OK) {
    throw new Error(lua.lua_tojsstring(L, -1));
  }
  if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    throw new Error(lua.lua_tojsstring(L, -1));
  }
  lua.lua_getglobal(L, to_luastring("FIXTURE_OUT"));
  const files = JSON.parse(lua.lua_tojsstring(L, -1));
  lua.lua_getglobal(L, to_luastring("TOOLS_OUT"));
  const tools = JSON.parse(lua.lua_tojsstring(L, -1));
  rmrf(fixture);
  for (const [rel, content] of Object.entries(files)) {
    const target = path.join(tmp, rel.replace("blueprint-exporter", "fixture"));
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, content, "utf8");
  }
  return { files, tools };
}

// ------------------------------------------------------------------ converters
function runPs(args) {
  return spawnSync(
    "powershell.exe",
    ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
     path.join(root, "tools", "json-to-string.ps1")].concat(args),
    { encoding: "utf8", timeout: 600000 }
  );
}
function runSh(args, scriptPath) {
  // Quoting a bash command through PowerShell is a trap, so the commands go
  // into a file and bash runs the file.
  const body = "#!/usr/bin/env bash\nset -e\nbash '" + toWsl(path.join(root, "tools", "json-to-string.sh")) +
    "' " + args.map((a) => (a.startsWith("-") ? a : toWsl(a)))
      .map((a) => "'" + a + "'").join(" ") + "\n";
  fs.writeFileSync(scriptPath, body, { encoding: "latin1" });
  return spawnSync("wsl.exe", ["-e", "bash", toWsl(scriptPath)],
    { encoding: "utf8", timeout: 900000 });
}

function walk(dir, into) {
  into = into || [];
  if (!fs.existsSync(dir)) return into;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, into);
    else into.push(p);
  }
  return into;
}
function sortAll(v) {
  if (Array.isArray(v)) return v.map(sortAll);
  if (v && typeof v === "object") {
    const o = {};
    for (const k of Object.keys(v).sort()) o[k] = sortAll(v[k]);
    return o;
  }
  return v;
}
function inflateString(p) {
  const raw = fs.readFileSync(p, "utf8").trim();
  if (raw[0] !== "0") throw new Error("no version byte: " + raw.slice(0, 4));
  return JSON.parse(zlib.inflateSync(Buffer.from(raw.slice(1), "base64")).toString("utf8"));
}
function readJson(p) { return JSON.parse(fs.readFileSync(p, "utf8")); }
function rel(from, p) { return path.relative(from, p).replace(/\\/g, "/"); }

// ------------------------------------------------------------------------ main
for (const d of [fixture, outPs, outSh, rawPs, rawSh]) rmrf(d);
fs.mkdirSync(tmp, { recursive: true });

const built = buildFixture();
const written = built.files;

// The mod ships a second copy of each converter because Factorio cannot read a
// file at runtime. Two copies drift unless something compares them, and only
// this side can: Lua has no file reads.
const embedded = Object.entries(built.tools);
check("embedded script text matches the file in the repository",
  embedded.length === 2 && embedded.every(([toolPath, text]) => {
    const disk = fs.readFileSync(path.join(root, ...toolPath.split("/")), "utf8");
    if (disk === text) return true;
    console.log("      differs: " + toolPath +
      " (" + Buffer.byteLength(text) + " embedded vs " +
      Buffer.byteLength(disk) + " on disk)");
    return false;
  }), JSON.stringify(Object.keys(built.tools)));
const names = Object.keys(written).sort();
const blueprints = names.filter((n) => n.endsWith(".json") &&
  !path.basename(n).startsWith("_") && path.basename(n) !== "manifest.json");
const sidecars = names.filter((n) => path.basename(n).startsWith("_book"));
console.log("fixture: " + names.length + " files, " + blueprints.length +
  " blueprints, " + sidecars.length + " book sidecars");

check("fixture has _export in blueprint json",
  blueprints.length > 0 && blueprints.every((n) => written[n].includes('"_export"')));
check("fixture has book sidecars", sidecars.length >= 3, sidecars.length);

const srcDir = fixture;
let r = runPs([srcDir, "-Out", outPs]);
check("powershell batch exit 0", r.status === 0, (r.stderr || "") + (r.stdout || ""));
r = runPs([srcDir, "-Out", rawPs, "-Raw"]);
check("powershell --raw exit 0", r.status === 0, (r.stderr || "") + (r.stdout || ""));

const shScript = path.join(tmp, "run-sh.sh");
r = runSh([srcDir, outSh], shScript);
const shAvailable = r.error === undefined && r.status !== null;
if (!shAvailable) {
  console.log("note: bash/wsl not available, skipping shell converter checks");
} else {
  check("bash batch exit 0", r.status === 0, (r.stderr || "") + (r.stdout || ""));
  r = runSh([srcDir, rawSh, "--raw"], shScript);
  check("bash --raw exit 0", r.status === 0, (r.stderr || "") + (r.stdout || ""));
}

// Each produced string must inflate to its .json minus _export.
for (const [label, dir, raw] of [["ps", outPs, false], ["ps --raw", rawPs, true],
                                 ["sh", outSh, false], ["sh --raw", rawSh, true]]) {
  if (dir === outSh || dir === rawSh) { if (!shAvailable) continue; }
  const produced = walk(dir).filter((f) => !f.endsWith(".err"));
  check(label + ": produced one file per blueprint",
    produced.length === blueprints.length, produced.length + " vs " + blueprints.length);

  let bad = null;
  for (const f of produced) {
    const sourceJson = path.join(srcDir, rel(dir, f).replace(/\.txt$/, ".json"));
    if (!fs.existsSync(sourceJson)) { bad = "produced for a file with no source: " + f; break; }
    const want = readJson(sourceJson);
    delete want._export;
    let got;
    try {
      got = raw ? readJson(f) : inflateString(f);
    } catch (e) { bad = rel(dir, f) + ": " + e.message; break; }
    if (JSON.stringify(sortAll(got)) !== JSON.stringify(sortAll(want))) {
      bad = rel(dir, f) + ": payload differs from its .json"; break;
    }
  }
  check(label + ": every string matches its .json without _export", bad === null, bad);

  const leaked = produced.filter((f) => ["_book.json", "manifest.json"]
    .includes(path.basename(f)));
  check(label + ": sidecars and manifest did not become blueprints",
    leaked.length === 0, leaked.join(", "));

  const rawLeak = produced.filter((f) => fs.readFileSync(f, "utf8").includes("_export"));
  check(label + ": _export absent from every output", rawLeak.length === 0, rel(dir, rawLeak[0] || ""));
}

if (shAvailable) {
  let disagree = null;
  for (const f of walk(outPs)) {
    const other = path.join(outSh, rel(outPs, f));
    if (!fs.existsSync(other)) { disagree = "missing in sh: " + rel(outPs, f); break; }
    const a = JSON.stringify(sortAll(inflateString(f)));
    const b = JSON.stringify(sortAll(inflateString(other)));
    if (a !== b) { disagree = "payload differs between converters: " + rel(outPs, f); break; }
  }
  check("powershell and bash agree on every payload", disagree === null, disagree);
}

// Single file with no output goes to stdout, which is the clipboard path.
r = runPs([path.join(srcDir, blueprints[0].replace("blueprint-exporter/", ""))]);
const one = (r.stdout || "").trim();
check("powershell single file prints one string to stdout",
  r.status === 0 && one.startsWith("0") && !one.includes("\n"),
  one.slice(0, 40));

console.log(failures === 0 ? "\nconverters: all checks passed" :
  "\nconverters: " + failures + " failure(s)");
process.exit(failures === 0 ? 0 : 1);
