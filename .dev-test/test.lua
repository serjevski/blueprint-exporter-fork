-- Tests for json.lua, naming.lua, compat.lua, export.lua (API: M.start/M.process)
-- Run with: node .dev-test/run.js

local Json = require("scripts.json")
local Naming = require("scripts.naming")
local Compat = require("scripts.compat")

-- ------------------------------------------------------------------- helpers
local failures, checks = 0, 0
local function check(name, ok, extra)
  checks = checks + 1
  if ok then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (extra ~= nil and ("  -> " .. tostring(extra)) or ""))
  end
end

local function raises(fn) return not pcall(fn) end
local function eq(a, b)
  return a == b, "\n--- got ---\n" .. tostring(a) .. "\n--- want ---\n" .. tostring(b)
end

-- ======================================================== json.lua: decode
local v = Json.decode('{"b":[1,2,{"a":true}],"c":null,"d":{},"e":[],"f":"x","g":false}')
check("decode: zagniezdzona tablica", v.b[1] == 1 and v.b[2] == 2 and v.b[3].a == true)
check("decode: null jako sentynel", v.c == Json.null and v.c ~= nil)
check("decode: pusty obiekt", type(v.d) == "table" and next(v.d) == nil)
check("decode: pusta tablica", type(v.e) == "table" and #v.e == 0)
check("decode: duplicate keys - ostatnie wygrywa", Json.decode('{"a":1,"a":2}').a == 2)

check("decode: odrzuca pusty obiekt", raises(function() Json.decode("{}") end))
check("decode: odrzuca pusta tablice", raises(function() Json.decode("[]") end))
check("decode: odrzuca goly tekst", raises(function() Json.decode('"ala"') end))
check("decode: odrzuca liczbe", raises(function() Json.decode("42") end))
check("decode: odrzuca nil", raises(function() Json.decode(nil) end))
check("decode: odrzuca puste wejscie", raises(function() Json.decode("") end))
check("decode: odrzuca brak dwukropka", raises(function() Json.decode('{"a" 1}') end))
check("decode: odrzuca brak nawiasu", raises(function() Json.decode('{"a":1') end))
check("decode: odrzuca przecinek w obiekcie", raises(function() Json.decode('{"a":1,}') end))
check("decode: odrzuca przecinek w tablicy", raises(function() Json.decode('{"a":[1,]}') end))
check("decode: odrzuca zle slowo kluczowe", raises(function() Json.decode('{"a":tru}') end))
check("decode: odrzuca zla liczbe", raises(function() Json.decode('{"a":1.2.3}') end))
check("decode: odrzuca nie domkniety tekst", raises(function() Json.decode('{"a":"ala}') end))
check("decode: odrzuca zly escape", raises(function() Json.decode('{"a":"a\\qb"}') end))
check("decode: odrzuca escape bez znaku", raises(function() Json.decode('{"a":"a\\}') end))
check("decode: odrzuca nadmiar na koncu", raises(function() Json.decode('{"a":1}}') end))
check("decode: odrzuca sam nawias zamykajacy", raises(function() Json.decode("}") end))
check("decode: akceptuje biale znaki", Json.decode(' \n\t{"a": 1} \n').a == 1)
check("decode: escape unicode", Json.decode([=[{"a":"\u00e7"}]=]).a == "\195\167", Json.decode([=[{"a":"\u00e7"}]=]).a)
check("decode: surrogate pair", Json.decode('{"a":"\\ud83d\\ude00"}').a == "\240\159\152\128")
check("decode: escape /", Json.decode('{"a":"\\/"}').a == "/")

-- ======================================================== json.lua: encode
check("encode: empty object", Json.encode({}) == "{}", Json.encode({}))
check("encode: empty array", Json.encode(Json.array({})) == "[]", Json.encode(Json.array({})))
check("encode: null sentynel", Json.encode({a = Json.null}) == '{\n  "a": null\n}', Json.encode({a = Json.null}))
check("encode: large integer", Json.encode({a = 17179869188}) == '{\n  "a": 17179869188\n}', Json.encode({a = 17179869188}))
check("encode: -0 -> 0", Json.encode({a = -0.0}) == '{\n  "a": 0\n}', Json.encode({a = -0.0}))
check("encode: fractions", Json.encode({a = 0.5, b = -1.5}) == '{\n  "a": 0.5,\n  "b": -1.5\n}', Json.encode({a = 0.5, b = -1.5}))
check("encode: escaped string", Json.encode({a = 'a"b\\c\nd\te'}) == '{\n  "a": "a\\"b\\\\c\\nd\\te"\n}', Json.encode({a = 'a"b\\c\nd\te'}))
check("encode: UTF-8 passthrough", Json.encode({a = "zaolc"}) == '{\n  "a": "zaolc"\n}', Json.encode({a = "zaolc"}))
check("encode: deterministic order",
  Json.encode(Json.normalize_keys(Json.decode('{"b":1,"a":2}')))
    == Json.encode(Json.normalize_keys(Json.decode('{"a":2,"b":1}'))))

-- ======================================================== json.lua: normalize
local n = Json.normalize_keys(Json.decode('{"A":{"B":1},"a":{"C":2}}'))
check("normalize: collision gets suffix", n.a.b == 1 and n.a__2.c == 2, Json.encode(n))
local deep = Json.normalize_keys(Json.decode('{"Root":{"Deep":{"MiXeD":true}}}'))
check("normalize: recursion", deep.root.deep.mixed == true, Json.encode(deep))
local once = Json.normalize_keys(Json.decode('{"Item":"x","item__2":"y"}'))
check("normalize: untouched collisions", once.item == "x" and once.item__2 == "y", Json.encode(once))
check("normalize: idempotent", Json.encode(Json.normalize_keys(once)) == Json.encode(once))
check("normalize: array preserved",
  Json.encode(Json.normalize_keys(Json.decode('{"a":[1,2,3]}'))) == '{\n  "a": [\n    1,\n    2,\n    3\n  ]\n}')
check("normalize: empty array preserved",
  Json.encode(Json.normalize_keys(Json.decode('{"a":[],"b":{}}'))) == '{\n  "a": [],\n  "b": {}\n}')

-- ======================================================== json.lua: full sort test
local src = '{"Blueprint":{"Zeta":1,"alpha":2,"Item":3,"item":4,"snap-to-grid":{"Y":1,"X":0}}}'
local want = [[{
  "blueprint": {
    "alpha": 2,
    "item": 3,
    "item__2": 4,
    "snap-to-grid": {
      "x": 0,
      "y": 1
    },
    "zeta": 1
  }
}]]
check("encode: full sort + lower + collision",
  eq(Json.encode(Json.normalize_keys(Json.decode(src))), want))

-- ======================================================== naming.lua
check("naming: entry_name", Naming.entry_name(1, "Test", "blueprint") == "001_Test", Naming.entry_name(1, "Test", "blueprint"))
check("naming: forbidden chars", Naming.entry_name(7, "a/b:c*d?\"e", "blueprint") == "007_a_b_c_d__e", Naming.entry_name(7, "a/b:c*d?\"e", "blueprint"))
check("naming: fallback on type", Naming.entry_name(3, "", "blueprint-book") == "003_blueprint-book", Naming.entry_name(3, "", "blueprint-book"))
-- UTF-8 validator: truncating a label must not leave a partial sequence
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

check("naming: UTF-8 truncation stays valid",
  (function()
    local two, three = "\209\156", "\224\164\168"
    for tail = 0, 6 do
      for _, unit in ipairs({ "a", two, three, " " .. two, two .. "b" .. three }) do
        local label = "start" .. unit:rep(30):sub(1, tail * 3)
        local name = Naming.entry_name(1, label, "blueprint")
        if not valid_utf8(name) then return false end
        if #name > #"001_blueprint" + 60 then return false end
      end
    end
    return true
  end)())
check("naming: long ASCII label keeps full 60 bytes",
  (function()
    local name = Naming.entry_name(1, string.rep("x", 100), "blueprint")
    return name == "001_" .. string.rep("x", 60), name
  end)())

-- ======================================================== compat.lua
local rec = { valid = true, label = "test" }
check("compat: is_preview returns false", Compat.is_preview(rec) == false)
check("compat: label from record", Compat.get_label(rec, nil) == "test")

-- stub helpers.json_to_table for fallback
helpers = { json_to_table = Json.decode, decode_string = function(text) return text end }
local rec2 = { valid = true, label = nil }
check("compat: label from exchange string",
  Compat.get_label(rec2, '0{"blueprint":{"label":"from_string"}}') == "from_string")

-- ======================================================== export.lua: integration
local Export = require("scripts.export")

local writes, printed, current_player

helpers = {
  write_file = function(path, content, append, player_index)
    writes[path] = content
  end,
  decode_string = function(text) return text end,
  json_to_table = Json.decode,
  -- Factorio serializes nested tables, so the stub has to as well.
  table_to_json = function(t)
    local function esc(s) return '"' .. s:gsub('"', '\\"') .. '"' end
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

game = {
  tick = 4242,
  blueprints = {},
  get_player = function() return current_player end,
}
storage = {}

local function make_record(label, payload, rtype, contents)
  return {
    valid = true,
    type = rtype or "blueprint",
    label = label,
    contents = contents or {},
    export_record = function(self) return "0" .. payload end,
  }
end

local function run_export(player_bp, game_bp)
  writes, printed = {}, {}
  game.blueprints = game_bp or {}
  current_player = {
    index = 1,
    connected = true,
    force = { index = 1 },
    blueprints = player_bp,
    -- export.lua calls player.print({ ... }) with a dot, so the first argument
    -- is the message itself (Factorio accepts both call styles).
    print = function(msg) printed[#printed + 1] = msg end,
  }
  Export.start(current_player)
  local g = 0
  while storage.job and g < 100 do
    Export.process()
    g = g + 1
  end
  return writes, printed
end

local function keys_of(t)
  local n = {}
  for k in pairs(t) do n[#n + 1] = k end
  table.sort(n)
  return table.concat(n, " | ")
end

local function find_msg(prefix, msgs)
  for _, msg in ipairs(msgs or {}) do
    if type(msg) == "table" and msg[1] == prefix then return msg end
  end
  return nil
end

-- ---- Test 1: single blueprint
local payload = '{"blueprint":{"item":"transport-belt","label":"Test","entities":[{"entity_number":1,"name":"transport-belt","position":{"x":0.5,"y":-1.5}}],"version":17179869188,"snap-to-grid":{"orientation":{}}}}'
local want_json = [[{
  "blueprint": {
    "entities": [
      {
        "entity_number": 1,
        "name": "transport-belt",
        "position": {
          "x": 0.5,
          "y": -1.5
        }
      }
    ],
    "item": "transport-belt",
    "label": "Test",
    "snap-to-grid": {
      "orientation": {}
    },
    "version": 17179869188
  }
}
]]

local w, msgs = run_export({ make_record("Test", payload) })
check("export: txt file with exchange string",
  w["blueprint-exporter/player/001_Test.txt"] == "0" .. payload .. "\n",
  tostring(w["blueprint-exporter/player/001_Test.txt"]))
check("export: json file with normalized JSON",
  eq(w["blueprint-exporter/player/001_Test.json"], want_json))
check("export: json is valid JSON",
  pcall(function() Json.decode(w["blueprint-exporter/player/001_Test.json"]) end))

local manifest = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: manifest has txt path",
  (function() for _, p in ipairs(manifest.files or {}) do if p == "player/001_Test.txt" then return true end end return false end)())
check("export: manifest has json path",
  (function() for _, p in ipairs(manifest.files or {}) do if p == "player/001_Test.json" then return true end end return false end)())

local done = find_msg("blueprint-exporter.export-done", msgs)
check("export: done message ok=1", done and done[2] == 1, tostring(done))
check("export: done message skipped=0", done and done[3] == 0, tostring(done))
check("export: done message failed=0", done and done[4] == 0, tostring(done))

-- ---- Test 2: book with child
local child = make_record("Child", '{"blueprint":{"item":"inserter"}}')
local book = make_record("Book", nil, "blueprint-book", { [1] = child })
book.export_record = function() error("book has no string") end
w, msgs = run_export({ book })
check("export: book creates directory",
  w["blueprint-exporter/player/001_Book/001_Child.json"] ~= nil, keys_of(w))
check("export: book has no own file",
  w["blueprint-exporter/player/001_Book.json"] == nil, keys_of(w))

local manifest2 = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: manifest child txt",
  (function() for _, p in ipairs(manifest2.files or {}) do if p == "player/001_Book/001_Child.txt" then return true end end return false end)())
check("export: manifest child json",
  (function() for _, p in ipairs(manifest2.files or {}) do if p == "player/001_Book/001_Child.json" then return true end end return false end)())

-- ---- Test 3: invalid record (skipped)
local bad = { valid = false, type = "blueprint", label = "Bad" }
w, msgs = run_export({ bad })
local skipped = find_msg("blueprint-exporter.export-done", msgs)
check("export: invalid record skipped", skipped and skipped[3] >= 1, tostring(skipped))

-- ---- Test 4: broken payload => .txt only
w, msgs = run_export({ make_record("Broken", "not json at all") })
check("export: broken payload writes txt",
  w["blueprint-exporter/player/001_Broken.txt"] ~= nil, keys_of(w))
check("export: broken payload no json",
  w["blueprint-exporter/player/001_Broken.json"] == nil, keys_of(w))
check("export: broken payload message",
  find_msg("blueprint-exporter.export-json-failed", msgs) ~= nil,
  keys_of(msgs))

-- ---- Test 5: key normalization end-to-end
local mixed = '{"Blueprint":{"Label":"Test","Snap-To-Grid":{"X":0,"Y":1},"Item":"belt","item":"other"}}'
w = run_export({ make_record("Mixed", mixed) })
local json_text = w["blueprint-exporter/player/001_Mixed.json"]
local decoded = Json.decode(json_text)
check("export: keys lowercase", decoded.blueprint.label == "Test", json_text)
check("export: keys sorted",
  json_text:find('"item"') < json_text:find('"item__2"')
    and json_text:find('"item__2"') < json_text:find('"label"')
    and json_text:find('"label"') < json_text:find('"snap%-to%-grid"'), json_text)
check("export: collision handled",
  decoded.blueprint.item == "belt" and decoded.blueprint.item__2 == "other", json_text)
check("export: no uppercase keys in output",
  not json_text:find('"%u[^"]*":'), json_text)

-- ---- Test 6: game library
w = run_export({}, { make_record("GameItem", '{"blueprint":{"item":"rocket"}}') })
check("export: game library",
  w["blueprint-exporter/game/001_GameItem.json"] ~= nil, keys_of(w))

-- ---- Test 7: determinism
local first = run_export({ make_record("Test", payload) })
local second = run_export({ make_record("Test", payload) })
check("export: deterministic",
  first["blueprint-exporter/player/001_Test.json"]
    == second["blueprint-exporter/player/001_Test.json"])

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then error("tests failed", 0) end
