"use strict";
/*
 * Validates scripts/naming.lua against a real export directory.
 *
 * Unit tests can only invent labels; this one takes the library as it really
 * is. Every .txt is inflated, its label and directory are pushed through the
 * real Lua code, and the resulting path must fit the budget, hold no markup
 * and stay valid UTF-8. Node's zlib and JSON.parse do the unpacking, so the
 * check needs nothing but the harness dependencies.
 *
 * Usage: node .dev-test/check_real_export.js <path to blueprint-exporter>
 *   e.g. node .dev-test/check_real_export.js "../script-output/blueprint-exporter"
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const root = path.resolve(__dirname, "..");
const outDir = process.argv[2];
if (!outDir) {
  console.error("usage: node .dev-test/check_real_export.js <path to blueprint-exporter>");
  process.exit(2);
}
if (!fs.existsSync(outDir)) {
  console.error("no such directory: " + outDir);
  process.exit(2);
}

function walk(dir, into) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, into);
    else if (e.name.endsWith(".txt")) into.push(p);
  }
  return into;
}

const rows = [];
let unreadable = 0;
for (const file of walk(outDir, [])) {
  const raw = fs.readFileSync(file, "utf8").trim();
  if (!raw) continue;
  let label;
  try {
    const payload = zlib.inflateSync(Buffer.from(raw.slice(1), "base64"));
    const data = JSON.parse(payload.toString("utf8"));
    const body = data[Object.keys(data)[0]];
    label = body && body.label ? body.label : "";
  } catch (err) {
    unreadable++;
    continue;
  }
  const rel = path.relative(outDir, path.dirname(file)).split(path.sep).join("/");
  rows.push({ dir: rel === "" ? "." : rel, label });
}

const REAL_DATA = rows.map((r) => JSON.stringify(r)).join("\n") + "\n";

const CHECK = `
local Naming = require("scripts.naming")
local Json = require("scripts.json")

local function valid_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    local len
    if b < 0x80 then len = 1
    elseif b >= 0xC2 and b <= 0xDF then len = 2
    elseif b >= 0xE0 and b <= 0xEF then len = 3
    elseif b >= 0xF0 and b <= 0xF4 then len = 4
    else return false end
    if i + len - 1 > n then return false end
    for j = 1, len - 1 do
      local c = s:byte(i + j)
      if c < 0x80 or c > 0xBF then return false end
    end
    i = i + len
  end
  return true
end

--- Directories are named the way export.lua names books: sanitize, then clamp
--- with a reserve so the children still get a usable name.
local function rebuild_dir(dir)
  local out = {}
  for seg in dir:gmatch("[^/]+") do
    local parent = #out > 0 and table.concat(out, "/") or ""
    local name = Naming.fit(parent, Naming.sanitize(seg), "", Naming.DIR_RESERVE)
    out[#out + 1] = name ~= "" and name or seg
  end
  return table.concat(out, "/")
end

local n, over, markup, invalid, empty, maxu = 0, 0, 0, 0, 0, 0
local idx = {}
for line in (REAL_DATA .. "\\n"):gmatch("([^\\n]*)\\n") do
  if line ~= "" then
    local ok, rec = pcall(Json.decode, line)
    if ok and type(rec) == "table" then
      n = n + 1
      local dir = rebuild_dir(rec.dir)
      idx[dir] = (idx[dir] or 0) + 1
      local name = Naming.fit(dir, Naming.entry_name(idx[dir], rec.label, "blueprint"), ".json")
      local full = dir .. "/" .. name .. ".json"
      local u = Naming.u16_len(full)
      if u > maxu then maxu = u end
      if u > Naming.PATH_BUDGET then
        over = over + 1
        print("OVER BUDGET (" .. u .. "): " .. full)
      end
      if name:find("%[") or name:find("%]") then
        markup = markup + 1
        print("MARKUP LEFT: " .. name)
      end
      if not valid_utf8(name) then
        invalid = invalid + 1
        print("INVALID UTF-8: " .. name)
      end
      if name == "" or name == string.format("%03d_", idx[dir]) then empty = empty + 1 end
    end
  end
end

print("records checked       :", n)
print("over PATH_BUDGET      :", over)
print("markup left in name   :", markup)
print("invalid UTF-8         :", invalid)
print("fell back to type name:", empty)
print("deepest path (UTF-16) :", maxu, "of budget", Naming.PATH_BUDGET)
process_fail = (over + markup + invalid > 0)
`;

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_getglobal(L, to_luastring("package"));
lua.lua_pushstring(
  L,
  to_luastring([path.join(root, "?.lua"), path.join(root, "?", "init.lua")].join(";"))
);
lua.lua_setfield(L, -2, to_luastring("path"));
lua.lua_pop(L, 1);

const bytes = to_luastring(REAL_DATA);
lua.lua_pushlstring(L, bytes, bytes.length);
lua.lua_setglobal(L, to_luastring("REAL_DATA"));

if (lauxlib.luaL_loadstring(L, to_luastring(CHECK)) !== lua.LUA_OK) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}
if (lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0) !== lua.LUA_OK) {
  console.error(lua.lua_tojsstring(L, -1));
  process.exit(1);
}

lua.lua_getglobal(L, to_luastring("process_fail"));
const failed = lua.lua_toboolean(L, -1);
console.log(unreadable > 0 ? `skipped ${unreadable} unreadable .txt` : "all .txt decoded");
console.log(failed ? "REAL EXPORT CHECK FAILED" : "REAL EXPORT CHECK OK");
process.exit(failed ? 1 : 0);
