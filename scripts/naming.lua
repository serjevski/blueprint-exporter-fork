-- Czyste funkcje nazewnictwa plików/katalogów eksportu. Bez API Factorio.
local M = {}

local MAX_LABEL_BYTES = 60

--- Length of the UTF-8 sequence starting at byte b, or 0 when b cannot start
--- one (lone continuation byte, overlong lead, or a byte above U+10FFFF).
local function utf8_seq_len(b)
  if b < 0x80 then return 1 end
  if b >= 0xC2 and b <= 0xDF then return 2 end
  if b >= 0xE0 and b <= 0xEF then return 3 end
  if b >= 0xF0 and b <= 0xF4 then return 4 end
  return 0
end

--- Drops bytes that do not form a valid UTF-8 sequence. The label becomes a
--- path segment on disk, so a stray byte would be written verbatim and make
--- the whole file unreadable for git tooling that assumes UTF-8.
local function utf8_scrub(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local len = utf8_seq_len(s:byte(i))
    if len > 0 and i + len - 1 <= n then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Length of the prefix of s that fits in limit and ends on a UTF-8 character
--- boundary (cutting inside a sequence would leave half of a character).
local function utf8_floor(s, limit)
  local i, last_ok = 1, 0
  while i <= #s and i <= limit do
    local len = utf8_seq_len(s:byte(i))
    if len == 0 or i + len - 1 > limit then break end
    i = i + len
    last_ok = i - 1
  end
  return last_ok
end

-- Prefiks numeryczny gwarantuje unikalność rodzeństwa (dwa rekordy nie dzielą
-- indeksu) i wyklucza zastrzeżone nazwy Windows (CON, NUL, ...).
local function sanitize_label(label)
  -- znaki zakazane w ścieżkach Windows + bajty sterujące
  local s = label:gsub('[<>:"/\\|%?%*%c]', "_")
  s = utf8_scrub(s)
  s = s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
  if #s > MAX_LABEL_BYTES then
    s = s:sub(1, utf8_floor(s, MAX_LABEL_BYTES))
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
