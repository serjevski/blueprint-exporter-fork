-- Czyste funkcje nazewnictwa plików/katalogów eksportu. Bez API Factorio.
local M = {}

local MAX_LABEL_BYTES = 60

-- Prefiks numeryczny gwarantuje unikalność rodzeństwa (dwa rekordy nie dzielą
-- indeksu) i wyklucza zastrzeżone nazwy Windows (CON, NUL, ...).
local function sanitize_label(label)
  -- znaki zakazane w ścieżkach Windows + bajty sterujące
  local s = label:gsub('[<>:"/\\|%?%*%c]', "_")
  s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
  if #s > MAX_LABEL_BYTES then
    -- cięcie rozcięło sekwencję UTF-8 tylko, gdy pierwszy odcięty bajt
    -- jest bajtem kontynuacji (0x80-0xBF) — wtedy zdejmij resztki sekwencji
    local cut = s:byte(MAX_LABEL_BYTES + 1)
    s = s:sub(1, MAX_LABEL_BYTES)
    if cut >= 0x80 and cut <= 0xBF then
      while #s > 0 and s:byte(#s) >= 0x80 and s:byte(#s) <= 0xBF do
        s = s:sub(1, #s - 1)
      end
      if #s > 0 and s:byte(#s) >= 0xC0 then
        s = s:sub(1, #s - 1)
      end
    end
    s = s:gsub("[%s%.]+$", "")
  end
  return s
end

--- Nazwa wpisu w drzewie eksportu, np. "007_Smelting".
--- @param index number pozycja rekordu (ItemStackIndex lub pozycja top-level)
--- @param label string|nil etykieta rekordu (może być pusta)
--- @param record_type string fallback nazwy, gdy brak etykiety
function M.entry_name(index, label, record_type)
  local base = label and sanitize_label(label) or ""
  if base == "" then
    base = record_type
  end
  return string.format("%03d_%s", index, base)
end

return M
