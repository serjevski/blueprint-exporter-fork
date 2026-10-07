-- Rekursywny eksport biblioteki blueprintów do script-output/blueprint-exporter/.
-- Tree: a book becomes a directory, a blueprint/planner becomes a .txt with
-- the exchange string plus a .json holding the same decoded JSON (keys in the
-- order the source file listed).
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
local Tools = require("scripts.tools")

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
-- Node: { kind="book", source, path, rel_dir, name, label, book_path, children={} }
-- Leaf: { kind="record", source, path, rel_dir, index, book_path }
--
-- book_path is the chain of original book labels (markup included) from the
-- root down to the container of the entry. Directory names lose the markup, so
-- without this chain the real name of a book could not be recovered -- the
-- label of a book is not stored anywhere else, because a book has no file of
-- its own. It is plain strings, so storage survives save/load.
local BOOK_FILE = "_book.json"

-- How many name components a book and its deepest descendant occupy. A name is
-- fitted once, top-down, so the only way a directory can leave room for what
-- goes under it is to know how deep that goes.
local function subtree_levels(records)
  local deepest = 1
  for _, entry in ipairs(sorted_entries(records)) do
    local record = entry.record
    if record.valid and not Compat.is_preview(record)
      and record.type == "blueprint-book" then
      local below = subtree_levels(record.contents) + 1
      if below > deepest then deepest = below end
    end
  end
  return deepest
end

local function build_queue(records, source, path, parent_node, rel_dir, label_path, queue, stats)
  for _, entry in ipairs(sorted_entries(records)) do
    local record = entry.record
    if not record.valid or Compat.is_preview(record) then
      stats.skipped = stats.skipped + 1
    else
      local sub_path = {}
      for i, v in ipairs(path) do sub_path[i] = v end
      sub_path[#sub_path + 1] = entry.index
      if record.type == "blueprint-book" then
        -- Książka nie dostaje pliku z stringiem: jego zawartość duplikowałaby
        -- wszystkie dzieci i zaśmiecałaby diffy. Zamiast tego dostaje _book.json
        -- z oryginalną etykietą -- jedyne miejsce, gdzie nazwa książki przeżywa.
        local label = Compat.get_label(record, nil)
        local name = Naming.entry_name(entry.index, label, record.type)
        -- +1: subtree_levels counts the components under the book, while fit
        -- shares the budget over those plus the directory itself.
        name = Naming.fit(rel_dir, name, "", Naming.DIR_RESERVE,
          subtree_levels(record.contents) + 1)
        local node = {
          kind = "book",
          source = source,
          path = sub_path,
          rel_dir = rel_dir,
          name = name,
          label = label,
          book_path = label_path,
          children = {},
        }
        parent_node.children[#parent_node.children + 1] = node
        queue[#queue + 1] = node
        local child_labels = {}
        for i, v in ipairs(label_path) do child_labels[i] = v end
        child_labels[#child_labels + 1] = label or ""
        build_queue(record.contents, source, sub_path, node, rel_dir .. "/" .. name, child_labels, queue, stats)
      else
        local leaf = {
          kind = "record",
          source = source,
          path = sub_path,
          rel_dir = rel_dir,
          index = entry.index,
          book_path = label_path,
        }
        parent_node.children[#parent_node.children + 1] = leaf
        queue[#queue + 1] = leaf
      end
    end
  end
end

-- Manifest as a tree (not a flat path list): the backup script can tell a
-- directory that exists on purpose from one left behind by a removed book.
-- Every book directory holds _book.json, so it is never empty.
local function build_manifest(node)
  local files = {}
  local dirs = {}
  for _, child in ipairs(node.children) do
    if child.kind == "record" then
      for _, file in ipairs(child.manifest_paths or {}) do
        files[#files + 1] = file
      end
    else
      if child.wrote_book_file then
        files[#files + 1] = child.name .. "/" .. BOOK_FILE
      end
      local sub = build_manifest(child)
      for _, f in ipairs(sub.files) do files[#files + 1] = child.name .. "/" .. f end
      for _, d in ipairs(sub.dirs) do dirs[#dirs + 1] = child.name .. "/" .. d end
      if #sub.files > 0 or #sub.dirs > 0 or child.wrote_book_file then
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

--- Metadata strings come straight from the game and may hold bytes that are not
--- valid UTF-8, which Json.encode would write verbatim into the file. Unlike a
--- file name these fields must keep their markup, so only the bytes go.
local function scrub_list(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = Naming.utf8_scrub(v) end
  return Json.array(out)
end

-- An exchange string is '0' + base64(zlib(JSON)). The .json file comes from
-- inflating that payload and re-writing the same JSON with our own encoder,
-- so the file stays readable for git: original key order, fixed indents, and
-- fields (_label, _book) carrying the exact case we were given. Everything
-- Factorio wrote into the record is passed through untouched.
-- Independent of .txt -- a broken payload only drops the .json (pcall below).
--
-- _export carries what the file system cannot keep: the label with its markup
-- intact, and the chain of book names this record sits in. It is added after
-- normalize_keys, so it lands after the Factorio payload rather than sorting
-- into it.
local function to_json(exchange_string, label, book_path)
  local payload = helpers.decode_string(exchange_string:sub(2))
  local data = Json.normalize_keys(Json.decode(payload))
  data._export = {
    label = label and Naming.utf8_scrub(label),
    book_path = scrub_list(book_path),
  }
  return Json.encode(data)
end

--- Contents of the _book.json sidecar: the only place a book's real name
--- survives, since a book produces no exchange-string file of its own.
local function book_json(node)
  return Json.encode({
    type = "blueprint-book",
    label = node.label and Naming.utf8_scrub(node.label),
    book_path = scrub_list(node.book_path),
  })
end

-- The converters are rewritten on every export, unconditionally. Factorio Lua
-- cannot stat or read a file, so there is no way to ask whether the copy in
-- script-output is current; writing them again costs two small files and
-- guarantees the user always has the version that matches this mod.
local function write_tools(player)
  local paths = {}
  for _, tool in ipairs(Tools) do
    local ok = pcall(helpers.write_file, OUTPUT_ROOT .. tool.path, tool.text, false,
      player.index)
    if ok then paths[#paths + 1] = tool.path end
  end
  return paths
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
  -- Listed in files as well as under tools: these paths really were written,
  -- and a manifest that omitted them would get them deleted as orphans by the
  -- backup script that prunes what the previous manifest claimed.
  local tools = write_tools(player)
  for _, path in ipairs(tools) do files[#files + 1] = path end

  local manifest = helpers.table_to_json({
    format = 3,
    tick = game.tick,
    files = files,
    dirs = dirs,
    tools = tools,
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
    books = 0,
  }
  local roots = {
    player = { kind = "root", name = "player", children = {} },
    game = { kind = "root", name = "game", children = {} },
  }
  build_queue(player.blueprints, "player", {}, roots.player, Naming.root_dir("player"), {}, queue, stats)
  build_queue(game.blueprints, "game", {}, roots.game, Naming.root_dir("game"), {}, queue, stats)

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
  job.stats.books = job.stats.books or 0

  -- odczyt player.blueprints/game.blueprints buduje tablicę referencji —
  -- raz na tick, nie raz na rekord
  local roots = { player = player.blueprints, game = game.blueprints }

  local done = 0
  while done < RECORDS_PER_TICK and job.pos <= #job.queue do
    local entry = job.queue[job.pos]
    job.pos = job.pos + 1
    done = done + 1

    if entry.kind == "book" then
      -- the sidecar is self-contained: its label and book_path were captured
      -- when the queue was built, so no record lookup is needed (and a book
      -- would fail export_record on purpose)
      local path = entry.rel_dir .. "/" .. entry.name .. "/" .. BOOK_FILE
      local ok = pcall(helpers.write_file, OUTPUT_ROOT .. path, book_json(entry) .. "\n", false, player.index)
      if ok then
        -- the same table is a node of the manifest tree, so this is what makes
        -- the directory appear in the manifest
        entry.wrote_book_file = true
        job.stats.books = job.stats.books + 1
      else
        job.stats.failed = job.stats.failed + 1
        job.stats.failures[#job.stats.failures + 1] = path
      end
    else
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
          local json_ok, json_str = pcall(to_json, str, label, entry.book_path)
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
  end

  if job.pos > #job.queue then
    finish(job, player)
  elseif job.pos - 1 >= job.next_report then
    job.next_report = job.next_report + PROGRESS_EVERY
    player.print({ "blueprint-exporter.export-progress", job.pos - 1, #job.queue })
  end
end

return M
