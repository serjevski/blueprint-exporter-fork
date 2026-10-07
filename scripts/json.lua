-- Deterministic JSON (parser + serializer) for the blueprint export.
--
-- helpers.json_to_table collapses [] into {} (an empty Lua table carries no
-- type hint) and helpers.table_to_json walks pairs in hash order; either one
-- alone would give unstable diffs in git. Our parser tags arrays with the
-- ARRAY_MT metatable and replays the original field order on encode, so the
-- same blueprint yields a byte-identical file on every export.
--
-- No Factorio API here -- the module can be tested outside the game.
local M = {}

-- Sentinel for JSON null: nil cannot survive in a Lua table (holes in #t).
M.null = setmetatable({}, { __tostring = function() return "null" end })

local ARRAY_MT = {}

-- Reserved field name used to carry the key order from decode into encode.
-- Cannot collide with a real Factorio JSON key. Only set on objects that
-- actually have keys: an empty object must stay empty for next()/pairs().
local ORDER_FIELD = "__json_key_order"

--- Marks a table as a JSON array (only needed to tell an empty [] from an object).
function M.array(items)
  return setmetatable(items or {}, ARRAY_MT)
end

local function is_array(value)
  return getmetatable(value) == ARRAY_MT
end

-- ------------------------------------------------------------------- decode

local ESCAPES = {
  ['"'] = '"',
  ["\\"] = "\\",
  ["/"] = "/",
  b = "\b",
  f = "\f",
  n = "\n",
  r = "\r",
  t = "\t",
}

local function utf8_from_codepoint(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end

--- Decodes JSON text into Lua values (objects = hash table, arrays = table
--- tagged with ARRAY_MT, null = M.null). Raises an error on malformed input.
function M.decode(text)
  if type(text) ~= "string" then
    error("json: expected string, got " .. type(text), 0)
  end
  local pos, len = 1, #text

  local function fail(message)
    error(string.format("json: %s at offset %d", message, pos), 0)
  end

  local function skip_ws()
    while pos <= len do
      local b = text:byte(pos)
      if b == 32 or b == 9 or b == 10 or b == 13 then
        pos = pos + 1
      else
        return
      end
    end
  end

  local function take(char)
    if text:byte(pos) ~= string.byte(char) then
      fail("expected '" .. char .. "'")
    end
    pos = pos + 1
  end

  local function hex4(offset)
    local digits = text:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]", offset)
    if not digits then fail("bad \\u escape") end
    return tonumber(digits, 16)
  end

  local function parse_string()
    take('"')
    local chunks = {}
    while true do
      local head = text:find('["\\]', pos)
      if not head then fail("unterminated string") end
      if head > pos then chunks[#chunks + 1] = text:sub(pos, head - 1) end
      local marker = text:sub(head, head)
      pos = head + 1
      if marker == '"' then return table.concat(chunks) end

      local esc = text:sub(pos, pos)
      if esc == "u" then
        local cp = hex4(pos + 1)
        pos = pos + 5
        if cp >= 0xD800 and cp <= 0xDBFF then
          if text:sub(pos, pos + 1) ~= "\\u" then fail("lone high surrogate") end
          local low = hex4(pos + 2)
          if low < 0xDC00 or low > 0xDFFF then fail("bad surrogate pair") end
          pos = pos + 6
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
        end
        chunks[#chunks + 1] = utf8_from_codepoint(cp)
      elseif ESCAPES[esc] then
        chunks[#chunks + 1] = ESCAPES[esc]
        pos = pos + 1
      else
        fail("unknown escape \\" .. esc)
      end
    end
  end

  local function parse_number()
    local raw = text:match("^-?%d+%.?%d*[eE][%+%-]?%d+", pos)
      or text:match("^-?%d+%.?%d*", pos)
    if not raw then fail("invalid number") end
    local value = tonumber(raw)
    if not value then fail("invalid number " .. raw) end
    pos = pos + #raw
    return value
  end

  local parse_value

  local function parse_object()
    take("{")
    local object, keys = {}, {}
    skip_ws()
    if text:sub(pos, pos) == "}" then
      pos = pos + 1
      return object
    end
    while true do
      skip_ws()
      if text:sub(pos, pos) ~= '"' then fail("expected string key") end
      local key = parse_string()
      skip_ws()
      take(":")
      skip_ws()
      object[key] = parse_value()
      keys[#keys + 1] = key
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "}" then
        pos = pos + 1
        object[ORDER_FIELD] = keys
        return object
      else
        fail("expected ',' or '}'")
      end
    end
  end

  local function parse_array()
    take("[")
    local array = setmetatable({}, ARRAY_MT)
    skip_ws()
    if text:sub(pos, pos) == "]" then
      pos = pos + 1
      return array
    end
    while true do
      skip_ws()
      array[#array + 1] = parse_value()
      skip_ws()
      local c = text:sub(pos, pos)
      if c == "," then
        pos = pos + 1
      elseif c == "]" then
        pos = pos + 1
        return array
      else
        fail("expected ',' or ']'")
      end
    end
  end

  parse_value = function()
    if pos > len then fail("unexpected end of input") end
    local c = text:sub(pos, pos)
    if c == "{" then return parse_object() end
    if c == "[" then return parse_array() end
    if c == '"' then return parse_string() end
    if text:find("^true", pos) then pos = pos + 4 return true end
    if text:find("^false", pos) then pos = pos + 5 return false end
    if text:find("^null", pos) then pos = pos + 4 return M.null end
    local b = text:byte(pos)
    if b == 45 or (b >= 48 and b <= 57) then return parse_number() end
    fail("unexpected value")
  end

  skip_ws()
  local value = parse_value()
  skip_ws()
  if pos <= len then fail("trailing characters") end
  -- A Factorio blueprint string always wraps an object with a top-level key
  -- (blueprint, blueprint_book, upgrade_planner, deconstruction_planner).
  if type(value) ~= "table" or next(value) == nil then
    error("expected a non-empty JSON object", 0)
  end
  return value
end

-- ---------------------------------------------------------- key normalization

--- Copies a value, replaying the field order the source JSON listed, then any
--- key that was added later, sorted, so hand-built tables still encode
--- deterministically.
--- Keys are NOT lowercased: Factorio's own strings are case sensitive --
--- "Blueprint" and "blueprint" name different entities -- so folding them
--- would corrupt the payload while pretending to tidy it.
--- Collisions (e.g. Item and item) lose no data: the first key in the
--- original byte order keeps its name, later ones get __2, __3, ... suffixes.
function M.normalize_keys(value)
  if type(value) ~= "table" then return value end
  -- The null sentinel is a table, so without this guard the recursion rebuilds
  -- it into an empty object and "null" silently becomes "{}" in the export.
  if value == M.null then return value end

  if is_array(value) then
    local array = setmetatable({}, ARRAY_MT)
    for i = 1, #value do
      array[i] = M.normalize_keys(value[i])
    end
    return array
  end

  -- Use the key order the parser recorded, or fall back to sorting for a
  -- table that was built by hand (no ORDER_FIELD).
  local keys = value[ORDER_FIELD]
  if not keys then
    keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
  end

  local object = {}
  local taken = {}
  for _, key in ipairs(keys) do
    local name = key
    local final = name
    local suffix = 2
    while taken[final] do
      final = name .. "__" .. suffix
      suffix = suffix + 1
    end
    taken[final] = true
    object[final] = M.normalize_keys(value[key])
  end
  -- Propagate the recorded order so encode can replay it on the copy.
  if keys == value[ORDER_FIELD] then object[ORDER_FIELD] = keys end
  return object
end

-- ------------------------------------------------------------------- encode

local STRING_ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function utf8_seq_len(byte)
  if byte < 0x80 then return 1 end
  if byte >= 0xF0 then return 4 end
  if byte >= 0xE0 then return 3 end
  if byte >= 0xC0 then return 2 end
  return 1 -- osierocony bajt kontynuacji — wyjsciowo niepelny UTF-8
end

--- Escapes the control bytes JSON forbids. The Lua classes %d and %c are
--- locale-sensitive (under UTF-8 %d also covers bytes 0xC2-0xF4) and %g means
--- "~%printable" -- both would swallow multi-byte characters. So: explicit
--- ASCII thresholds plus UTF-8 validation.
local function unicode_escape(value)
  local out, buf = {}, {}
  local n = #value
  local function flush()
    if #buf > 0 then out[#out + 1] = table.concat(buf) end
    buf = {}
  end
  local i = 1
  while i <= n do
    local ch = value:sub(i, i)
    local b = value:byte(i)
    local short = STRING_ESCAPES[ch]
    if short then
      -- quote, backslash and the C0 control bytes have short JSON escapes
      flush()
      out[#out + 1] = short
      i = i + 1
    elseif b < 0x20 then
      flush()
      out[#out + 1] = string.format("\\u%04x", b)
      i = i + 1
    elseif b < 0x80 then
      buf[#buf + 1] = ch
      i = i + 1
    else
      local len = utf8_seq_len(b)
      if i + len - 1 <= n then
        buf[#buf + 1] = value:sub(i, i + len - 1)
      else
        -- truncated UTF-8 at the end -- escape only the bytes that are present
        local avail = n - i + 1
        flush()
        for k = 0, avail - 1 do
          out[#out + 1] = string.format("\\u%04x", value:byte(i + k))
        end
      end
      i = i + len
    end
  end
  flush()
  return table.concat(out)
end

local function encode_string(value)
  return '"' .. unicode_escape(value) .. '"'
end

-- Factorio 2.0 encodes item versions as uint64 (major << 48) and positions as
-- doubles -- integral values must print without ".0", fractions without loss.
local function encode_number(value)
  if value ~= value or value == math.huge or value == -math.huge then return "0" end
  if value == 0 then return "0" end
  if value == math.floor(value) and math.abs(value) < 2 ^ 53 then
    return string.format("%.0f", value)
  end
  -- "%.14g" (what Lua's tostring gives) does not survive a round trip: a color
  -- channel written as 0.49803921580314636 came back as 0.49803921580315, so
  -- the .json was not the blueprint it came from. Take the shortest form that
  -- parses back to the same double, which keeps 0.5 short and 2.13e-17 exact.
  for precision = 15, 17 do
    local text = string.format("%." .. precision .. "g", value)
    if tonumber(text) == value then return text end
  end
  return string.format("%.17g", value)
end

--- Serializes a value to JSON, reproducing the key order the value carries
--- (the order parsed from the source, or insertion order for built tables),
--- with fixed indentation (two spaces by default) so the file shape stays
--- stable between exports.
function M.encode(value, indent)
  indent = indent or "  "
  local chunks = {}

  local write_value

  write_value = function(current, depth)
    local kind = type(current)
    if current == M.null or current == nil then
      chunks[#chunks + 1] = "null"
    elseif kind == "boolean" then
      chunks[#chunks + 1] = tostring(current)
    elseif kind == "number" then
      chunks[#chunks + 1] = encode_number(current)
    elseif kind == "string" then
      chunks[#chunks + 1] = encode_string(current)
    elseif kind == "table" then
      if is_array(current) then
        if #current == 0 then
          chunks[#chunks + 1] = "[]"
          return
        end
        local pad = indent:rep(depth + 1)
        chunks[#chunks + 1] = "[\n"
        for i = 1, #current do
          if i > 1 then chunks[#chunks + 1] = ",\n" end
          chunks[#chunks + 1] = pad
          write_value(current[i], depth + 1)
        end
        chunks[#chunks + 1] = "\n" .. indent:rep(depth) .. "]"
      else
        -- Use the recorded order when we have it, then append any key that was
        -- added later (sorted) so that metadata injected after decode still
        -- ends up in a deterministic place. The recorded list is copied, not
        -- mutated: encode may run on the same table more than once.
        local recorded = rawget(current, ORDER_FIELD)
        local keys = {}
        if recorded == nil then
          for key in pairs(current) do
            if key ~= ORDER_FIELD then keys[#keys + 1] = key end
          end
          table.sort(keys)
        else
          local listed = {}
          -- Mark ORDER_FIELD itself as listed so it is never emitted as data.
          listed[ORDER_FIELD] = true
          for i = 1, #recorded do
            local key = recorded[i]
            if current[key] ~= nil and not listed[key] then
              listed[key] = true
              keys[#keys + 1] = key
            end
          end
          local extras = {}
          for key in pairs(current) do
            if not listed[key] then extras[#extras + 1] = key end
          end
          table.sort(extras)
          for i = 1, #extras do keys[#keys + 1] = extras[i] end
        end
        if #keys == 0 then
          chunks[#chunks + 1] = "{}"
          return
        end
        local pad = indent:rep(depth + 1)
        chunks[#chunks + 1] = "{\n"
        for i = 1, #keys do
          if i > 1 then chunks[#chunks + 1] = ",\n" end
          local key = keys[i]
          chunks[#chunks + 1] = pad .. encode_string(tostring(key)) .. ": "
          write_value(current[key], depth + 1)
        end
        chunks[#chunks + 1] = "\n" .. indent:rep(depth) .. "}"
      end
    else
      error("json: cannot encode " .. kind, 0)
    end
  end

  write_value(value, 0)
  return table.concat(chunks)
end

return M
