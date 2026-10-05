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

-- ---- BB-code markup must not reach the disk
check("naming: markup stripped",
  eq(Naming.entry_name(1, "[item=rail]CityBlocks", "blueprint"), "001_CityBlocks"))
check("naming: closing tags stripped",
  eq(Naming.entry_name(1, "[color=purple]Rails[/color][/font]", "blueprint"), "001_Rails"))
check("naming: color with numbers stripped",
  eq(Naming.entry_name(4, "[color=185,95,0]Interchanges[/color]", "blueprint"), "004_Interchanges"))
check("naming: markup-only label falls back to type",
  eq(Naming.entry_name(2, "[color=red][/color]", "blueprint"), "002_blueprint"))
check("naming: spaces left by markup collapse",
  eq(Naming.entry_name(1, "[item=x]  A   B  ", "blueprint"), "001_A B"))
check("naming: markup inside text removed, text kept",
  eq(Naming.entry_name(1, "A[item=x]B", "blueprint"), "001_AB"))
-- a lone bracket is not markup and must survive
check("naming: lone bracket kept",
  eq(Naming.entry_name(1, "outer[", "blueprint"), "001_outer["))
-- Factorio truncates long labels itself, and the cut can land inside a tag
check("naming: tag truncated at end of label is removed",
  eq(Naming.sanitize("etc[item=splitter][item=fast-insert"), "etc"))
check("naming: tag name truncated before its = is removed",
  eq(Naming.sanitize("Rails[_fon"), "Rails"))
-- a bracket that does not look like a tag is text and stays
check("naming: bracket with a space inside is kept",
  eq(Naming.sanitize("Base [see notes"), "Base [see notes"))
check("naming: numbered bracket is kept",
  eq(Naming.sanitize("Block [10x10]"), "Block [10x10]"))
check("naming: digit-only open bracket is kept",
  eq(Naming.sanitize("Block [10"), "Block [10"))

-- ---- invisible characters must not reach the disk (%c alone does not cover these)
local INVISIBLE = {
  { "C0 tab",        "\9" },
  { "DEL",           "\127" },
  { "C1 NEL",        "\194\133" },
  { "ZWSP",          "\226\128\139" },
  { "ZWJ",           "\226\128\141" },
  { "RLM",           "\226\128\143" },
  { "line separator", "\226\128\168" },
  { "RLE bidi",      "\226\128\171" },
  { "word joiner",   "\226\129\160" },
  { "BOM",           "\239\187\191" },
  { "interlinear",   "\239\191\185" },
}
for _, case in ipairs(INVISIBLE) do
  check("naming: drops " .. case[1],
    eq(Naming.entry_name(1, "a" .. case[2] .. "b", "blueprint"), "001_ab"))
end

-- ---- root directory names
check("naming: root_dir player", eq(Naming.root_dir("player"), "p"))
check("naming: root_dir game", eq(Naming.root_dir("game"), "g"))
check("naming: root_dir unknown passthrough", eq(Naming.root_dir("other"), "other"))

-- ---- UTF-16 counting (MAX_PATH counts units, not bytes or codepoints)
check("naming: u16_len ascii", Naming.u16_len("abc") == 3)
check("naming: u16_len cyrillic is 1 unit per char", Naming.u16_len("\209\156\209\156") == 2)
check("naming: u16_len astral is 2 units", Naming.u16_len("\240\159\152\128") == 2)

-- ---- path budget
check("naming: fit leaves a short name alone",
  eq(Naming.fit("p", "001_Short", ".json"), "001_Short"))
check("naming: fit truncates to the budget",
  (function()
    local name = Naming.fit("p", "001_" .. string.rep("x", 400), ".json")
    return Naming.u16_len("p/" .. name .. ".json") <= Naming.PATH_BUDGET,
      Naming.u16_len("p/" .. name .. ".json")
  end)())
check("naming: fit keeps the whole path inside the budget at depth",
  (function()
    -- directories are clamped with a reserve before their children are named,
    -- exactly as export.lua does; clamping a leaf under an over-budget
    -- directory is not something fit can fix after the fact
    local dir = "p"
    for _, seg in ipairs({ string.rep("d", 100), string.rep("e", 100) }) do
      dir = dir .. "/" .. Naming.fit(dir, seg, "", Naming.DIR_RESERVE)
    end
    local name = Naming.fit(dir, string.rep("n", 300), ".json")
    local total = Naming.u16_len(dir .. "/" .. name .. ".json")
    return total <= Naming.PATH_BUDGET and #name > 0, total
  end)())
check("naming: fit reserves room for children of a directory",
  (function()
    local dir = "p"
    local name = Naming.fit(dir, string.rep("d", 300), "", Naming.DIR_RESERVE)
    local child = Naming.fit(dir .. "/" .. name, string.rep("c", 300), ".json")
    return Naming.u16_len(dir .. "/" .. name .. "/" .. child .. ".json") <= Naming.PATH_BUDGET
      and #child > 0
  end)())
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

check("naming: truncation stays valid UTF-8 at every cut",
  (function()
    local two, three, four = "\209\156", "\224\164\168", "\240\159\152\128"
    for tail = 0, 12 do
      for _, unit in ipairs({ "a", two, three, four, " " .. two, two .. "b" .. three }) do
        -- the real pipeline: sanitize scrubs the label, fit then cuts on a
        -- boundary. Calling fit with a raw label would skip the scrubbing.
        local name = Naming.fit("p", Naming.entry_name(1, "start" .. unit:rep(60):sub(1, tail * 4), "blueprint"), ".json")
        if not valid_utf8(name) then return false, name end
        if Naming.u16_len("p/" .. name .. ".json") > Naming.PATH_BUDGET then return false, name end
      end
    end
    return true
  end)())
check("naming: sanitize leaves no leading or trailing dot or space",
  eq(Naming.sanitize("  .. A  B ..  "), "A B"))
check("naming: fit does not leave a trailing dot or space when it cuts",
  (function()
    local name = Naming.fit("p", "001_" .. string.rep("x", 200) .. " . ", ".json")
    return not name:find("[%. ]$"), name
  end)())
check("naming: entry_name itself no longer truncates",
  #Naming.entry_name(1, string.rep("x", 300), "blueprint") == #"001_" + 300)

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
  w["blueprint-exporter/p/001_Test.txt"] == "0" .. payload .. "\n",
  tostring(w["blueprint-exporter/p/001_Test.txt"]))
check("export: json file with normalized JSON",
  eq(w["blueprint-exporter/p/001_Test.json"], want_json))
check("export: json is valid JSON",
  pcall(function() Json.decode(w["blueprint-exporter/p/001_Test.json"]) end))

local manifest = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: manifest has txt path",
  (function() for _, p in ipairs(manifest.files or {}) do if p == "p/001_Test.txt" then return true end end return false end)())
check("export: manifest has json path",
  (function() for _, p in ipairs(manifest.files or {}) do if p == "p/001_Test.json" then return true end end return false end)())

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
  w["blueprint-exporter/p/001_Book/001_Child.json"] ~= nil, keys_of(w))
check("export: book has no own file",
  w["blueprint-exporter/p/001_Book.json"] == nil, keys_of(w))

local manifest2 = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: manifest child txt",
  (function() for _, p in ipairs(manifest2.files or {}) do if p == "p/001_Book/001_Child.txt" then return true end end return false end)())
check("export: manifest child json",
  (function() for _, p in ipairs(manifest2.files or {}) do if p == "p/001_Book/001_Child.json" then return true end end return false end)())

-- ---- Test 3: invalid record (skipped)
local bad = { valid = false, type = "blueprint", label = "Bad" }
w, msgs = run_export({ bad })
local skipped = find_msg("blueprint-exporter.export-done", msgs)
check("export: invalid record skipped", skipped and skipped[3] >= 1, tostring(skipped))

-- ---- Test 4: broken payload => .txt only
w, msgs = run_export({ make_record("Broken", "not json at all") })
check("export: broken payload writes txt",
  w["blueprint-exporter/p/001_Broken.txt"] ~= nil, keys_of(w))
check("export: broken payload no json",
  w["blueprint-exporter/p/001_Broken.json"] == nil, keys_of(w))
check("export: broken payload message",
  find_msg("blueprint-exporter.export-json-failed", msgs) ~= nil,
  keys_of(msgs))

-- ---- Test 5: key normalization end-to-end
local mixed = '{"Blueprint":{"Label":"Test","Snap-To-Grid":{"X":0,"Y":1},"Item":"belt","item":"other"}}'
w = run_export({ make_record("Mixed", mixed) })
local json_text = w["blueprint-exporter/p/001_Mixed.json"]
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
  w["blueprint-exporter/g/001_GameItem.json"] ~= nil, keys_of(w))

-- ---- Test 7: determinism
local first = run_export({ make_record("Test", payload) })
local second = run_export({ make_record("Test", payload) })
check("export: deterministic",
  first["blueprint-exporter/p/001_Test.json"]
    == second["blueprint-exporter/p/001_Test.json"])

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then error("tests failed", 0) end
