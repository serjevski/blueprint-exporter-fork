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
  -- Hand-built tables have no recorded order and encode sorted (deterministic).
  Json.encode({ a = 1, b = 2 }) == Json.encode({ b = 2, a = 1 }),
  Json.encode({ a = 1, b = 2 }) .. " vs " .. Json.encode({ b = 2, a = 1 }))

-- ======================================================== json.lua: normalize
-- Keys keep their case; only sorting and collision-suffixing happen.
local n = Json.normalize_keys(Json.decode('{"A":{"B":1},"a":{"C":2}}'))
check("normalize: keys keep their case", n.A.B == 1 and n.a.C == 2, Json.encode(n))
local deep = Json.normalize_keys(Json.decode('{"Root":{"Deep":{"MiXeD":true}}}'))
check("normalize: recursion", deep.Root.Deep.MiXeD == true, Json.encode(deep))
local once = Json.normalize_keys(Json.decode('{"Item":"x","item__2":"y"}'))
check("normalize: untouched collisions", once.Item == "x" and once.item__2 == "y", Json.encode(once))
check("normalize: idempotent", Json.encode(Json.normalize_keys(once)) == Json.encode(once))
check("normalize: null survives the copy",
  eq(Json.encode(Json.normalize_keys(Json.decode('{"a":null,"b":{"c":null}}'))),
     '{\n  "a": null,\n  "b": {\n    "c": null\n  }\n}'),
  Json.encode(Json.normalize_keys(Json.decode('{"a":null}'))))
check("normalize: null in an array survives",
  eq(Json.encode(Json.normalize_keys(Json.decode('{"a":[null,1]}'))),
     '{\n  "a": [\n    null,\n    1\n  ]\n}'))

-- ---- doubles must survive the round trip, they are positions and colors
local ROUND_TRIP = {
  0.49803921580314636, 0.7745016813278198, 1.9999999935758013,
  2.13e-17, -12.5, 0.1, 1 / 3, -0.000000000000000000000001,
  3.141592653589793, 1e300, 5e-324,
}
for _, number in ipairs(ROUND_TRIP) do
  check(string.format("encode: double round trip %.17g", number),
    (function()
      local text = Json.encode({ v = number })
      local back = Json.decode(text).v
      return back == number, text
    end)())
end
check("encode: short values stay short",
  eq(Json.encode({ a = 0.5, b = 0.1, c = 12.5 }),
     '{\n  "a": 0.5,\n  "b": 0.1,\n  "c": 12.5\n}'),
  Json.encode({ a = 0.5, b = 0.1, c = 12.5 }))
check("encode: full pipeline keeps doubles exact",
  (function()
    local src = '{"blueprint":{"color":[0.49803921580314636,0.7745016813278198]}}'
    local out = Json.encode(Json.normalize_keys(Json.decode(src)))
    local decoded = Json.decode(out).blueprint.color
    return decoded[1] == 0.49803921580314636 and decoded[2] == 0.7745016813278198, out
  end)())
check("normalize: array preserved",
  Json.encode(Json.normalize_keys(Json.decode('{"a":[1,2,3]}'))) == '{\n  "a": [\n    1,\n    2,\n    3\n  ]\n}')
check("normalize: empty array preserved",
  Json.encode(Json.normalize_keys(Json.decode('{"a":[],"b":{}}'))) == '{\n  "a": [],\n  "b": {}\n}')

-- ======================================================== json.lua: order preservation
local src = '{"Blueprint":{"Zeta":1,"alpha":2,"Item":3,"item":4,"snap-to-grid":{"Y":1,"X":0}}}'
-- The order Factorio wrote is the order the file keeps, byte for byte. Case is
-- preserved too, so "Item" and "item" stay two distinct keys with no suffix.
local want = [[{
  "Blueprint": {
    "Zeta": 1,
    "alpha": 2,
    "Item": 3,
    "item": 4,
    "snap-to-grid": {
      "Y": 1,
      "X": 0
    }
  }
}]]
check("encode: original key order preserved",
  eq(Json.encode(Json.normalize_keys(Json.decode(src))), want),
  Json.encode(Json.normalize_keys(Json.decode(src))))

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
check("naming: fit shares the budget with the levels under it",
  (function()
    local a = Naming.fit("p", string.rep("d", 300), "", 0, 3)
    local dir = "p/" .. a
    local b = Naming.fit(dir, string.rep("c", 300), "", 0, 2)
    local leaf = Naming.fit(dir .. "/" .. b, string.rep("l", 300), ".json")
    local total = Naming.u16_len(dir .. "/" .. b .. "/" .. leaf .. ".json")
    return total <= Naming.PATH_BUDGET and #a > 0 and #b > 0, total
  end)())
check("naming: a shared budget is smaller than a lone one",
  #Naming.fit("p", string.rep("d", 300), "", 0, 3) < #Naming.fit("p", string.rep("d", 300), "", 0, 1))
check("naming: one level left behaves exactly as before",
  Naming.fit("p", string.rep("d", 300), ".json") == Naming.fit("p", string.rep("d", 300), ".json", 0, 1))
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
-- utf8_scrub is for metadata fields: bytes go, markup stays
check("naming: utf8_scrub drops invalid bytes but keeps markup",
  eq(Naming.utf8_scrub("a" .. string.char(0xC3) .. "[b=c]"), "a[b=c]"))
-- a lead byte is only a character if the continuation bytes are real ones
check("naming: stray lead byte does not reach the file name",
  eq(Naming.entry_name(1, "A" .. string.char(0xC3) .. "B", "blueprint"), "001_AB"))
check("naming: lead byte followed by ASCII is not a character",
  eq(Naming.sanitize(string.char(0xE2) .. "8B"), "8B"))
check("naming: surrogate half is dropped",
  eq(Naming.sanitize("a" .. string.char(0xED, 0xA0, 0x80) .. "b"), "ab"))
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
-- blueprint keeps the order Factorio wrote; _export is added afterwards and
-- sorts (hand-built table), so it lands after the payload.
local want_json = [[{
  "blueprint": {
    "item": "transport-belt",
    "label": "Test",
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
    "version": 17179869188,
    "snap-to-grid": {
      "orientation": {}
    }
  },
  "_export": {
    "book_path": [],
    "label": "Test"
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
check("export: keys preserve case", decoded.Blueprint.Label == "Test", json_text)
check("export: keys sorted",
  (function()
    -- Keys preserve the source order (Blueprint → Label → Snap-To-Grid → Item → item).
    local from = json_text:find('"Blueprint"')
    local body = json_text:sub(from)
    local at = function(key)
      local pos = body:find(key, 1, true)
      return pos or math.huge
    end
    return at('"Label"') < at('"Snap-To-Grid"')
      and at('"Snap-To-Grid"') < at('"Item"')
      and at('"Item"') < at('"item"'), json_text
  end)())
check("export: two case-different keys coexist",
  decoded.Blueprint.Item == "belt" and decoded.Blueprint.item == "other", json_text)

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

-- ---- Test 8: _export metadata and the _book.json sidecar
local MARKED = "[item=rail][color=purple]City Blocks[/color][/font]"
local BOOK_MARKED = "[font=count-font]Rails[/font]"
local marked_leaf = make_record(MARKED, '{"blueprint":{"item":"transport-belt"}}')
local marked_book = make_record(BOOK_MARKED, nil, "blueprint-book", { [3] = marked_leaf })
marked_book.export_record = function() error("book has no string") end
w, msgs = run_export({ [7] = marked_book })

local marked_json = w["blueprint-exporter/p/007_Rails/003_City Blocks.json"]
check("export: markup is out of the file name", marked_json ~= nil, keys_of(w))
local meta = marked_json and Json.decode(marked_json)._export
check("export: _export keeps the label with markup",
  meta ~= nil and meta.label == MARKED, meta and Json.encode(meta))
check("export: _export.book_path is the book chain with markup",
  meta ~= nil and #meta.book_path == 1 and meta.book_path[1] == BOOK_MARKED,
  meta and Json.encode(meta.book_path))
check("export: _export follows the payload",
  marked_json ~= nil and marked_json:find('"_export"') > marked_json:find('"blueprint"'))

local sidecar_text = w["blueprint-exporter/p/007_Rails/_book.json"]
check("export: book writes a sidecar", sidecar_text ~= nil, keys_of(w))
local sidecar = sidecar_text and Json.decode(sidecar_text)
check("export: sidecar says it is a book",
  sidecar ~= nil and sidecar.type == "blueprint-book", sidecar_text)
check("export: sidecar keeps the book label with markup",
  sidecar ~= nil and sidecar.label == BOOK_MARKED, sidecar_text)
check("export: sidecar book_path is empty under a root",
  sidecar ~= nil and #sidecar.book_path == 0, sidecar_text)

local m8 = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: manifest lists the sidecar",
  (function()
    for _, p in ipairs(m8.files) do if p == "p/007_Rails/_book.json" then return true end end
    return false
  end)(), Json.encode(m8.files))
check("export: manifest lists the book directory",
  (function()
    for _, p in ipairs(m8.dirs) do if p == "p/007_Rails" then return true end end
    return false
  end)(), Json.encode(m8.dirs))

-- ---- converters travel inside the mod and are rewritten every export
local Tools = require("scripts.tools")
check("tools: module lists both converters", #Tools == 2, #Tools)
check("export: manifest format is 3", m8.format == 3, tostring(m8.format))
check("export: manifest lists the tools",
  m8.tools ~= nil and #m8.tools == 2, Json.encode(m8.tools or {}))
check("export: tools are in files too, so a pruner keeps them",
  (function()
    for _, tool in ipairs(Tools) do
      local found = false
      for _, p in ipairs(m8.files) do if p == tool.path then found = true end end
      if not found then return false end
    end
    return true
  end)(), Json.encode(m8.files))
check("export: converter files are written verbatim",
  (function()
    for _, tool in ipairs(Tools) do
      local written = w["blueprint-exporter/" .. tool.path]
      if written ~= tool.text then return false end
    end
    return true
  end)(), tostring(w["blueprint-exporter/tools/json-to-string.sh"]))
check("export: shipped scripts keep LF endings",
  (function()
    for _, tool in ipairs(Tools) do
      if tool.text:find("\r") then return false end
    end
    return true
  end)())
check("export: powershell converter ships its doc comment",
  (Tools[1].text:sub(1, 2) == "<#"), Tools[1].text:sub(1, 10))
check("export: bash converter ships its shebang",
  (Tools[2].text:sub(1, 11) == "#!/usr/bin/" or Tools[2].text:sub(1, 2) == "#!"),
  Tools[2].text:sub(1, 20))

-- Even an empty library has to leave working converters behind: the whole point
-- of rewriting them is that the user always has the current version.
w = run_export({}, {})
check("export: empty library still ships the converters",
  (function()
    for _, tool in ipairs(Tools) do
      if w["blueprint-exporter/" .. tool.path] == nil then return false end
    end
    return true
  end)(), keys_of(w))
local m_empty = Json.decode(w["blueprint-exporter/manifest.json"])
check("export: empty manifest still claims the tools",
  m_empty.tools ~= nil and #m_empty.tools == 2, Json.encode(m_empty))

-- ---- Test 9: nested books accumulate the chain
local deep_leaf = make_record("Deep", '{"blueprint":{"item":"pipe"}}')
local inner = make_record("Inner", nil, "blueprint-book", { [1] = deep_leaf })
inner.export_record = function() error("no string") end
local outer = make_record("Outer", nil, "blueprint-book", { [1] = inner })
outer.export_record = function() error("no string") end
w = run_export({ outer })
local deep_text = w["blueprint-exporter/p/001_Outer/001_Inner/001_Deep.json"]
check("export: nested book path exists", deep_text ~= nil, keys_of(w))
local deep_meta = deep_text and Json.decode(deep_text)._export
check("export: nested book_path runs outer to inner",
  deep_meta ~= nil and #deep_meta.book_path == 2
    and deep_meta.book_path[1] == "Outer" and deep_meta.book_path[2] == "Inner",
  deep_meta and Json.encode(deep_meta.book_path))
local inner_side = w["blueprint-exporter/p/001_Outer/001_Inner/_book.json"]
check("export: nested sidecar carries its ancestors",
  (function()
    local s = inner_side and Json.decode(inner_side)
    return s ~= nil and #s.book_path == 1 and s.book_path[1] == "Outer"
  end)(), inner_side)

-- ---- Test 10: an empty book still leaves its name behind
local empty_book = make_record("[color=red]Void[/color]", nil, "blueprint-book", {})
empty_book.export_record = function() error("no string") end
w = run_export({ empty_book })
local void_side = w["blueprint-exporter/p/001_Void/_book.json"]
check("export: empty book leaves a sidecar", void_side ~= nil, keys_of(w))
check("export: empty book sidecar keeps markup in the label",
  void_side ~= nil and Json.decode(void_side).label == "[color=red]Void[/color]", void_side)

-- ---- Test 11: metadata stays valid UTF-8 even when the game label is not
local dirty = "Bad" .. string.char(0xC3) .. "[color=red]Tag[/color]"
local dirty_leaf = make_record(dirty, '{"blueprint":{"item":"pipe"}}')
w = run_export({ dirty_leaf })
local dirty_text = w["blueprint-exporter/p/001_BadTag.json"]
check("export: label with a stray byte still writes a file", dirty_text ~= nil, keys_of(w))
check("export: .json never contains invalid UTF-8",
  dirty_text ~= nil and valid_utf8(dirty_text), dirty_text)
check("export: _export keeps markup but loses the stray byte",
  dirty_text ~= nil and Json.decode(dirty_text)._export.label == "Bad[color=red]Tag[/color]",
  dirty_text and Json.decode(dirty_text)._export.label)

-- ---- Test 12: labels that clean to the same name must not share a path
-- Over half of a real library carries markup in front of the name. Strip it and
-- "[item=steel-plate] Roboport", "[item=copper-plate] Roboport" and a plain
-- "Roboport" all want 001_Roboport; 46 labels in one real library collapse this
-- way. The index prefix is the only thing keeping them apart, and a collision
-- would be silent -- helpers.write_file just overwrites.
local rob1 = make_record("[item=steel-plate] Roboport", '{"blueprint":{"item":"a"}}')
local rob2 = make_record("[item=copper-plate] Roboport", '{"blueprint":{"item":"b"}}')
local rob3 = make_record("Roboport", '{"blueprint":{"item":"c"}}')
w = run_export({ rob1, rob2, rob3 })
check("export: labels collapsing to one name get three paths",
  w["blueprint-exporter/p/001_Roboport.txt"] ~= nil
    and w["blueprint-exporter/p/002_Roboport.txt"] ~= nil
    and w["blueprint-exporter/p/003_Roboport.txt"] ~= nil, keys_of(w))
check("export: each copy remembers which label it came from",
  (function()
    for i, want in ipairs({ "[item=steel-plate] Roboport",
                            "[item=copper-plate] Roboport", "Roboport" }) do
      local text = w[string.format("blueprint-exporter/p/%03d_Roboport.json", i)]
      if text == nil or Json.decode(text)._export.label ~= want then return false end
    end
    return true
  end)())

-- Books collapse the same way, and two books on one directory would merge their
-- children instead of overwriting one file.
local core1 = make_record("[color=red]Core[/color]", nil, "blueprint-book",
  { [1] = make_record("One", '{"blueprint":{"item":"o"}}') })
core1.export_record = function() error("no string") end
local core2 = make_record("[color=blue]Core[/color]", nil, "blueprint-book",
  { [1] = make_record("Two", '{"blueprint":{"item":"t"}}') })
core2.export_record = function() error("no string") end
w = run_export({ core1, core2 })
check("export: books collapsing to one name get two directories",
  w["blueprint-exporter/p/001_Core/_book.json"] ~= nil
    and w["blueprint-exporter/p/002_Core/_book.json"] ~= nil
    and w["blueprint-exporter/p/001_Core/001_One.txt"] ~= nil
    and w["blueprint-exporter/p/002_Core/001_Two.txt"] ~= nil, keys_of(w))

-- ---- Test 13: every written path stays inside the budget, however it is built
-- Astral characters cost two UTF-16 units each, and a book name is repeated in
-- every path under it, so depth and astral labels attack the budget together.
local star = string.char(0xF0, 0x9F, 0x92, 0xA9)
local function nest(depth, leaf)
  local node = leaf
  for i = 1, depth do
    node = make_record(star .. " Book " .. i .. " " .. string.rep("глубина", 6),
      nil, "blueprint-book", { [1] = node })
    node.export_record = function() error("no string") end
  end
  return node
end
w = run_export({ nest(5, make_record(star .. " Leaf " .. string.rep("x", 200),
  '{"blueprint":{"item":"pipe"}}')) })
local over, longest = nil, 0
for path in pairs(w) do
  local rel = path:match("^blueprint%-exporter/(.+)$")
  if rel and not rel:match("^tools/") then
    local units = Naming.u16_len(rel)
    if units > longest then longest = units end
    if units > Naming.PATH_BUDGET then over = rel end
  end
end
check("export: deep nested path exists", longest > 0, keys_of(w))
check("export: no written path passes the UTF-16 budget",
  over == nil, tostring(over) .. " is " .. longest)
check("export: deep path keeps valid UTF-8 in every segment",
  (function()
    for path in pairs(w) do if not valid_utf8(path) then return false, path end end
    return true
  end)())

print(string.format("\n%d checks, %d failures", checks, failures))
if failures > 0 then error("tests failed", 0) end
if failures > 0 then error("tests failed", 0) end
