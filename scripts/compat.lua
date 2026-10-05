-- Warstwa zgodności Factorio 2.0 <-> 2.1 dla LuaRecord.
-- Odczyt nieistniejącego membera LuaRecord rzuca błąd, stąd wszystkie
-- odczyty wersjozależnych pól idą przez pcall.
local M = {}

--- 2.1.7 usunęło LuaRecord::is_blueprint_preview na rzecz is_preview.
function M.is_preview(record)
  local ok, v = pcall(function() return record.is_preview end)
  if ok and v ~= nil then return v end
  ok, v = pcall(function() return record.is_blueprint_preview end)
  if ok and v ~= nil then return v end
  return false
end

--- LuaRecord::label istnieje dopiero od 2.1.7; na 2.0 etykietę trzeba
--- wyciągnąć dekodując string wymiany (pierwszy bajt to wersja formatu).
--- @param exchange_string string|nil string z export_record(), używany tylko jako fallback
function M.get_label(record, exchange_string)
  local ok, label = pcall(function() return record.label end)
  if ok and label and label ~= "" then return label end
  if not exchange_string then return nil end
  local ok2, decoded = pcall(function()
    return helpers.json_to_table(helpers.decode_string(exchange_string:sub(2)))
  end)
  if not ok2 or type(decoded) ~= "table" then return nil end
  -- klucz główny zależy od typu: blueprint / blueprint_book /
  -- deconstruction_planner / upgrade_planner
  for _, key in ipairs({ "blueprint", "blueprint_book", "deconstruction_planner", "upgrade_planner" }) do
    local inner = decoded[key]
    if type(inner) == "table" and inner.label and inner.label ~= "" then
      return inner.label
    end
  end
  return nil
end

return M
