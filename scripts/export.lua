-- Rekursywny eksport biblioteki blueprintów do script-output/blueprint-exporter/.
-- Tree: a book becomes a directory, a blueprint/planner becomes a .txt with
-- the exchange string plus a .json holding the same decoded JSON (keys lowercased and sorted).
--
-- Eksport jest rozłożony na ticki: klik buduje w storage.job kolejkę ścieżek
-- indeksowych (samo wyliczenie struktury jest tanie), a process() woła
-- kosztowne export_record/write_file dla RECORDS_PER_TICK rekordów na tick.
-- W kolejce trzymamy ścieżki indeksów, NIE referencje LuaRecord — rekord jest
-- rozwiązywany ponownie przy przetwarzaniu (zmiana biblioteki w trakcie
-- eksportu = pominięcie rekordu, nie crash; brak wątpliwej serializacji
-- LuaRecord w storage przy save/load).
--
-- helpers.write_file nie umie kasować plików — sieroty po usuniętych
-- blueprintach sprząta backup.ps1 na podstawie manifest.json (zapisywanego
-- na końcu: przerwany eksport zostawia stary, spójny manifest).
local Naming = require("scripts.naming")
local Compat = require("scripts.compat")
local Json = require("scripts.json")

local M = {}

local OUTPUT_ROOT = "blueprint-exporter/"
local RECORDS_PER_TICK = 10
local PROGRESS_EVERY = 100
local MAX_REPORTED_FAILURES = 5

-- contents książki to słownik LuaRecord po ItemStackIndex (rzadki) —
-- posortowane klucze dają stabilną kolejność w diffach gita.
local function sorted_entries(records)
  local entries = {}
  for index, record in pairs(records) do
    entries[#entries + 1] = { index = index, record = record }
  end
  table.sort(entries, function(a, b) return a.index < b.index end)
  return entries
end

-- The queue mixes nodes (books) with leaves (file records), so manifest.json
-- rebuilds the directory tree instead of a list flattened into rel_dir.
-- Node: { kind="book", source, path, rel_dir, name, children={} }
-- Leaf: { kind="record", source, path, rel_dir, index }
local function build_queue(records, source, path, parent_node, rel_dir, queue, stats)
  for _, entry in ipairs(sorted_entries(records)) do
    local record = entry.record
    if not record.valid or Compat.is_preview(record) then
      stats.skipped = stats.skipped + 1
    else
      local sub_path = {}
      for i, v in ipairs(path) do sub_path[i] = v end
      sub_path[#sub_path + 1] = entry.index
      if record.type == "blueprint-book" then
        -- Książka nie dostaje własnego pliku: jej string duplikuje całą
        -- zawartość dzieci i zaśmiecałby diffy. Pusta książka nie zostawia śladu.
        local name = Naming.entry_name(entry.index, Compat.get_label(record, nil), record.type)
        name = Naming.fit(rel_dir, name, "", Naming.DIR_RESERVE)
        local node = {
          kind = "book",
          source = source,
          path = sub_path,
          rel_dir = rel_dir,
          name = name,
          children = {},
        }
        parent_node.children[#parent_node.children + 1] = node
        build_queue(record.contents, source, sub_path, node, rel_dir .. "/" .. name, queue, stats)
      else
        local leaf = {
          kind = "record",
          source = source,
          path = sub_path,
          rel_dir = rel_dir,
          index = entry.index,
        }
        parent_node.children[#parent_node.children + 1] = leaf
        queue[#queue + 1] = leaf
      end
    end
  end
end

-- Manifest as a tree (not a flat path list): backup.ps1 can tell an empty
-- directory left by a removed book apart from a directory holding files.
-- Empty directories drop out -- there is nothing to clean up after an empty book.
local function build_manifest(node)
  local files = {}
  local dirs = {}
  for _, child in ipairs(node.children) do
    if child.kind == "record" then
      for _, file in ipairs(child.manifest_paths or {}) do
        files[#files + 1] = file
      end
    else
      local sub = build_manifest(child)
      for _, f in ipairs(sub.files) do files[#files + 1] = child.name .. "/" .. f end
      for _, d in ipairs(sub.dirs) do dirs[#dirs + 1] = child.name .. "/" .. d end
      if #sub.files > 0 or #sub.dirs > 0 then
        dirs[#dirs + 1] = child.name
      end
    end
  end
  return { files = files, dirs = dirs }
end

local function prune_empty_manifest_dirs(manifest)
  local keep = {}
  for _, file in ipairs(manifest.files) do
    local prefix = ""
    for part in file:gmatch("[^/]+") do
      prefix = prefix .. (#prefix > 0 and "/" or "") .. part
      keep[prefix] = true
    end
  end
  local dirs = {}
  for _, dir in ipairs(manifest.dirs) do
    if keep[dir] then dirs[#dirs + 1] = dir end
  end
  return { files = manifest.files, dirs = dirs }
end

local function resolve(roots, entry)
  local record
  for depth, idx in ipairs(entry.path) do
    if depth == 1 then
      record = roots[entry.source][idx]
    else
      if not (record and record.valid and record.type == "blueprint-book") then return nil end
      record = record.contents[idx]
    end
    if not record then return nil end
  end
  return record
end

-- An exchange string is '0' + base64(zlib(JSON)). The .json file comes from
-- inflating that payload and re-writing the same JSON with our own encoder,
-- so the file stays readable for git: keys lowercased, sorted, fixed indents.
-- Independent of .txt -- a broken payload only drops the .json (pcall below).
local function to_json(exchange_string)
  local payload = helpers.decode_string(exchange_string:sub(2))
  return Json.encode(Json.normalize_keys(Json.decode(payload)))
end

local function finish(job, player)
  local stats = job.stats
  local files, dirs = {}, {}
  for _, root_name in ipairs({ "game", "player" }) do
    local node = job.manifest_roots and job.manifest_roots[root_name]
    if node then
      local manifest = prune_empty_manifest_dirs(build_manifest(node))
      local root = Naming.root_dir(root_name)
      for _, file in ipairs(manifest.files) do files[#files + 1] = root .. "/" .. file end
      for _, dir in ipairs(manifest.dirs) do dirs[#dirs + 1] = root .. "/" .. dir end
    end
  end
  local manifest = helpers.table_to_json({
    format = 2,
    tick = game.tick,
    files = files,
    dirs = dirs,
  })
  helpers.write_file(OUTPUT_ROOT .. "manifest.json", manifest .. "\n", false, player.index)

  player.print({ "blueprint-exporter.export-done", stats.ok, stats.skipped, stats.failed })
  for i = 1, math.min(#stats.failures, MAX_REPORTED_FAILURES) do
    player.print({ "blueprint-exporter.export-failed-item", stats.failures[i] })
  end
  if stats.json_failed > 0 then
    player.print({ "blueprint-exporter.export-json-failed", stats.json_failed })
    for i = 1, math.min(#stats.json_failures, MAX_REPORTED_FAILURES) do
      player.print({ "blueprint-exporter.export-failed-item", stats.json_failures[i] })
    end
  end
  storage.job = nil
end

function M.start(player)
  local job = storage.job
  if job then
    player.print({ "blueprint-exporter.export-busy", job.pos - 1, #job.queue })
    return
  end

  local queue = {}
  local stats = {
    ok = 0,
    skipped = 0,
    failed = 0,
    failures = {},
    json_failed = 0,
    json_failures = {},
  }
  local roots = {
    player = { kind = "root", name = "player", children = {} },
    game = { kind = "root", name = "game", children = {} },
  }
  build_queue(player.blueprints, "player", {}, roots.player, Naming.root_dir("player"), queue, stats)
  build_queue(game.blueprints, "game", {}, roots.game, Naming.root_dir("game"), queue, stats)

  storage.job = {
    player_index = player.index,
    queue = queue,
    pos = 1,
    next_report = PROGRESS_EVERY,
    manifest_roots = roots,
    stats = stats,
  }
  player.print({ "blueprint-exporter.export-started", #queue })
end

-- Wołane co tick z control.lua; bez aktywnego zadania wychodzi natychmiast.
function M.process()
  local job = storage.job
  if not job then return end

  local player = game.get_player(job.player_index)
  if not (player and player.connected) then
    storage.job = nil
    return
  end

  -- the job survives save/load: one started on 0.2.0 has no .json counters
  job.stats.json_failed = job.stats.json_failed or 0
  job.stats.json_failures = job.stats.json_failures or {}

  -- odczyt player.blueprints/game.blueprints buduje tablicę referencji —
  -- raz na tick, nie raz na rekord
  local roots = { player = player.blueprints, game = game.blueprints }

  local done = 0
  while done < RECORDS_PER_TICK and job.pos <= #job.queue do
    local entry = job.queue[job.pos]
    job.pos = job.pos + 1
    done = done + 1

    local record = resolve(roots, entry)
    if not record or not record.valid or Compat.is_preview(record) then
      job.stats.skipped = job.stats.skipped + 1
    else
      local ok, str = pcall(record.export_record, record)
      if not ok or type(str) ~= "string" then
        job.stats.failed = job.stats.failed + 1
        job.stats.failures[#job.stats.failures + 1] = entry.rel_dir .. "/#" .. entry.index
      else
        local label = Compat.get_label(record, str)
        local name = Naming.entry_name(entry.index, label, record.type)
        -- ".json" is the longer of the two extensions, so it is the one to budget for
        name = Naming.fit(entry.rel_dir, name, ".json")
        local base = entry.rel_dir .. "/" .. name
        helpers.write_file(OUTPUT_ROOT .. base .. ".txt", str .. "\n", false, player.index)
        entry.manifest_paths = { name .. ".txt" }
        job.stats.ok = job.stats.ok + 1

        -- .txt is the source of truth: if the payload will not decode, the
        -- record still reaches git -- only the readable .json variant is missing
        local json_ok, json_str = pcall(to_json, str)
        if json_ok and type(json_str) == "string" then
          helpers.write_file(OUTPUT_ROOT .. base .. ".json", json_str .. "\n", false, player.index)
          entry.manifest_paths[#entry.manifest_paths + 1] = name .. ".json"
        else
          job.stats.json_failed = job.stats.json_failed + 1
          job.stats.json_failures[#job.stats.json_failures + 1] = base .. ".json"
        end
      end
    end
  end

  if job.pos > #job.queue then
    finish(job, player)
  elseif job.pos - 1 >= job.next_report then
    job.next_report = job.next_report + PROGRESS_EVERY
    player.print({ "blueprint-exporter.export-progress", job.pos - 1, #job.queue })
  end
end

return M
