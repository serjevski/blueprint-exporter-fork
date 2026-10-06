-- Czyste funkcje nazewnictwa plikow/katalogow eksportu. Bez API Factorio.
local M = {}

-- The path budget is counted in UTF-16 code units, because that is what
-- Windows counts (MAX_PATH = 260 including the terminator). The previous limit
-- was 60 UTF-8 bytes per component, so the real length depended on the
-- alphabet: a Cyrillic label got 30 characters, a Latin one got 60.
--
-- A mod cannot know the length of its own install directory (there is no
-- file-system read API), so the budget covers the path relative to the export
-- root only. 140 leaves room for a root up to ~118 units, deeper than any
-- ordinary user profile, while the deepest path in a real 1800-file library
-- needs 114 once markup is stripped.
M.PATH_BUDGET = 140

-- Room kept inside a directory so that its children always get a usable name.
local DIR_RESERVE = 24

-- Both roots have to stay separate (player.blueprints must not share a
-- directory with game.blueprints), but the full words only eat the budget.
local ROOT_DIR = { player = "p", game = "g" }

--- Short directory name for an export root ("player" -> "p").
function M.root_dir(root)
  return ROOT_DIR[root] or root
end

--- Length of the UTF-8 sequence starting at byte b, or 0 when b cannot start
--- one (lone continuation byte, overlong lead, or a byte above U+10FFFF).
local function utf8_seq_len(b)
  if b < 0x80 then return 1 end
  if b >= 0xC2 and b <= 0xDF then return 2 end
  if b >= 0xE0 and b <= 0xEF then return 3 end
  if b >= 0xF0 and b <= 0xF4 then return 4 end
  return 0
end

--- Codepoint at byte i and its byte length; length 0 marks an invalid byte.
--- A lead byte alone is not enough: every following byte has to be a real
--- continuation byte, otherwise "A\xC3B" reads as one character and the stray
--- byte reaches the disk.
local function utf8_codepoint(s, i)
  local b1 = s:byte(i)
  local len = utf8_seq_len(b1)
  if len == 0 or i + len - 1 > #s then return nil, 0 end
  for j = 2, len do
    local b = s:byte(i + j - 1)
    if b < 0x80 or b > 0xBF then return nil, 0 end
  end
  if len == 3 and b1 == 0xED and s:byte(i + 1) >= 0xA0 then
    return nil, 0                       -- UTF-16 surrogate half, no valid pair
  end
  local b2, b3, b4 = s:byte(i + 1, i + 3)
  local cp
  if len == 1 then
    cp = b1
  elseif len == 2 then
    cp = (b1 % 0x20) * 0x40 + (b2 % 0x40)
  elseif len == 3 then
    cp = ((b1 % 0x10) * 0x40 + (b2 % 0x40)) * 0x40 + (b3 % 0x40)
  else
    cp = (((b1 % 0x08) * 0x40 + (b2 % 0x40)) * 0x40 + (b3 % 0x40)) * 0x40 + (b4 % 0x40)
  end
  return cp, len
end

--- UTF-16 code units, the unit MAX_PATH is measured in: anything outside the
--- BMP is a 4-byte UTF-8 sequence and becomes a surrogate pair.
function M.u16_len(s)
  local n, i = 0, 1
  while i <= #s do
    local len = utf8_seq_len(s:byte(i))
    if len == 0 then len = 1 end
    if len == 4 then n = n + 2 else n = n + 1 end
    i = i + len
  end
  return n
end

--- Byte index just past the last character that fits in limit UTF-16 units.
--- Cutting inside a sequence would leave half of a character on disk.
local function u16_floor(s, limit)
  local used, i, last = 0, 1, 0
  while i <= #s do
    local len = utf8_seq_len(s:byte(i))
    if len == 0 then len = 1 end
    local add = (len == 4 and 2 or 1)
    if used + add > limit then break end
    used = used + add
    i = i + len
    last = i - 1
  end
  return last
end

-- %c covers ASCII controls only, so C1 controls, zero-width joins, the BOM and
-- the bidi overrides would otherwise reach the disk: invisible, yet they still
-- break shell completion and diff tools. Dropped rather than replaced, because
-- an underscore for an invisible character is pure noise.
local function is_invisible(cp)
  if cp < 0x20 or cp == 0x7F then return true end          -- C0 controls + DEL
  if cp >= 0x80 and cp <= 0x9F then return true end        -- C1 controls
  if cp >= 0x200B and cp <= 0x200F then return true end    -- zero-width, LRM, RLM
  if cp == 0x2028 or cp == 0x2029 then return true end     -- line/paragraph separators
  if cp >= 0x202A and cp <= 0x202E then return true end    -- bidi embedding/override
  if cp >= 0x2060 and cp <= 0x2064 then return true end    -- word joiner, invisible ops
  if cp >= 0x206A and cp <= 0x206F then return true end    -- deprecated controls
  if cp == 0xFEFF then return true end                     -- BOM / ZWNBSP
  if cp >= 0xFFF9 and cp <= 0xFFFB then return true end    -- interlinear annotation
  return false
end

-- Characters Windows refuses inside a path component.
local FORBIDDEN = {}
for _, b in ipairs({ 0x3C, 0x3E, 0x3A, 0x22, 0x2F, 0x5C, 0x7C, 0x3F, 0x2A }) do
  FORBIDDEN[b] = true
end

-- Factorio BB-code is removed whole, value included. Half a tag is worse than
-- nothing: the old export turned "[/color]" into "[_color]" (the slash had
-- already become an underscore), so the markup could not be recovered, and it
-- still cost 55% of the characters in a real library's paths.
local MARKUP = "%[[/%a_][^%]]*%]"

-- Factorio truncates a label by itself, and the cut can land inside a tag
-- ("...etc[item=splitter][item=fast-insert"). A tag with a key that runs to the
-- end of the string without closing is that debris, not text someone typed.
-- The second form covers a tag name cut before its "=" ("[_fon" from
-- "[/font]"); requiring no spaces keeps "[see notes" alive.
local MARKUP_TAIL = "%[/?[%a_][%w_%-%.]*=[^%]]*$"
local MARKUP_TAIL_NAME = "%[/?[%a_][%w_%-%.]*$"

--- Drops bytes that do not form a valid UTF-8 sequence. Anything that reaches a
--- file must be valid UTF-8: Json.encode passes bytes through untouched, so one
--- stray byte would make the whole file unreadable for tooling that assumes
--- UTF-8. Markup is kept -- this is for metadata fields, sanitize is for names.
function M.utf8_scrub(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local cp, len = utf8_codepoint(s, i)
    if not cp then
      i = i + 1
    else
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    end
  end
  return table.concat(out)
end

--- Label as it may appear on disk: no markup, no invisible characters, no bytes
--- that are illegal in a Windows path, collapsed spaces, no trailing dots
--- (Windows trims them silently, which would desync the manifest).
function M.sanitize(label)
  local stripped = label:gsub(MARKUP, "")
  stripped = stripped:gsub(MARKUP_TAIL, ""):gsub(MARKUP_TAIL_NAME, "")
  local out, i, n = {}, 1, #stripped
  while i <= n do
    local cp, len = utf8_codepoint(stripped, i)
    if not cp then
      i = i + 1                        -- invalid UTF-8 byte, drop it
    else
      if is_invisible(cp) then
        -- dropped
      elseif len == 1 and FORBIDDEN[cp] then
        out[#out + 1] = "_"
      else
        out[#out + 1] = stripped:sub(i, i + len - 1)
      end
      i = i + len
    end
  end
  local s = table.concat(out)
  s = s:gsub("%s+", " ")
  return (s:gsub("^[%s%.]+", ""):gsub("[%s%.]+$", ""))
end

-- Prefiks numeryczny gwarantuje unikalnosc rodzenstwa (dwa rekordy nie dzielą
-- indeksu) i wyklucza zastrzeżone nazwy Windows (CON, NUL, ...).
function M.entry_name(index, label, record_type)
  local base = label and M.sanitize(label) or ""
  if base == "" then
    -- empty label, or one that was nothing but markup
    base = record_type
  end
  return string.format("%03d_%s", index, base)
end

--- Shortens name so that dir + "/" + name + ext fits PATH_BUDGET UTF-16 units.
--- Returns the name truncated on a character boundary, never empty.
---@param dir string directory the name will live in
---@param name string candidate name
---@param ext? string extension that will be appended ("" for a directory)
---@param reserve? number room to keep free for the children of a directory
---@param levels? number name components still to place, counting this one
---@return string
function M.fit(dir, name, ext, reserve, levels)
  ext = ext or ""
  reserve = reserve or 0
  levels = levels or 1
  local room = M.PATH_BUDGET - M.u16_len(dir) - 1 - M.u16_len(ext) - reserve
  if room < 1 then return name end           -- dir is already over budget
  -- A directory that takes the whole remaining budget leaves nothing for the
  -- names under it, and every one of those adds a separator to all the paths
  -- below. A five-deep library reached 504 units that way and Factorio wrote
  -- nothing at all, silently -- the exact failure this budget exists to stop.
  -- So the budget is shared with the levels still to come, which is also why
  -- the reserve for a direct child is not subtracted here: the share already
  -- leaves room for everything underneath, child included.
  if levels > 1 then
    room = math.max(1, math.floor((M.PATH_BUDGET - M.u16_len(dir) - 1) / levels))
  end
  if M.u16_len(name) <= room then return name end
  local cut = string.sub(name, 1, u16_floor(name, room))
  local trimmed = cut:gsub("[%s%.]+$", "")
  -- trimming must not hand back an empty name
  return trimmed ~= "" and trimmed or cut
end

M.DIR_RESERVE = DIR_RESERVE

return M
