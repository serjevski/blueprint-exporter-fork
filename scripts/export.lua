-- Rekursywny eksport biblioteki blueprintów do script-output/blueprint-exporter/.
-- Drzewo: książka = katalog, blueprint/planner = plik .txt ze stringiem wymiany.
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

-- Buduje płaską kolejkę liści; książki są rozwiązywane do katalogów już tu
-- (etykieta bez stringa wymiany — na 2.0 książka bez etykiety dostanie nazwę z typu).
local function build_queue(records, source, path, rel_dir, queue, stats)
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
        build_queue(record.contents, source, sub_path, rel_dir .. "/" .. name, queue, stats)
      else
        queue[#queue + 1] = { source = source, path = sub_path, rel_dir = rel_dir, index = entry.index }
      end
    end
  end
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

local function finish(job, player)
  local manifest = helpers.table_to_json({
    format = 1,
    tick = game.tick,
    files = job.manifest_files,
  })
  helpers.write_file(OUTPUT_ROOT .. "manifest.json", manifest .. "\n", false, player.index)

  player.print({ "blueprint-exporter.export-done", job.stats.ok, job.stats.skipped, job.stats.failed })
  for i = 1, math.min(#job.stats.failures, MAX_REPORTED_FAILURES) do
    player.print({ "blueprint-exporter.export-failed-item", job.stats.failures[i] })
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
  local stats = { ok = 0, skipped = 0, failed = 0, failures = {} }
  build_queue(player.blueprints, "player", {}, "player", queue, stats)
  build_queue(game.blueprints, "game", {}, "game", queue, stats)

  storage.job = {
    player_index = player.index,
    queue = queue,
    pos = 1,
    next_report = PROGRESS_EVERY,
    manifest_files = {},
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
        local rel_path = entry.rel_dir .. "/" .. name .. ".txt"
        helpers.write_file(OUTPUT_ROOT .. rel_path, str .. "\n", false, player.index)
        job.manifest_files[#job.manifest_files + 1] = rel_path
        job.stats.ok = job.stats.ok + 1
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
