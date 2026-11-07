-- Canonical (NFC) normalization, used to compare query text with buffer text.
--
-- Input methods and clipboards sometimes hand us decomposed text: `e` followed
-- by U+0301 instead of `é`, or Hangul jamo instead of a precomposed syllable.
-- Matching is byte based, so equivalent strings would otherwise not match.
--
-- Only composition is needed. Buffers normally hold NFC text already, and
-- normalizing a single composed character is a no-op, so we compose what we are
-- given instead of decomposing first. Several marks on one base are put into
-- canonical order before composing, which NFC requires. Compatibility folding
-- (NFKC) deliberately stays out of this module and belongs to codecs.
--
-- The tables are loaded lazily, so ASCII-only queries never pay for them. See
-- lua/jump/unicode_data.lua.

local text = require('jump.text')

local M = {}

local HANGUL_FIRST = 0xAC00
local HANGUL_LAST = 0xD7A3
local JAMO_L_FIRST = 0x1100
local JAMO_L_LAST = 0x1112
local JAMO_V_FIRST = 0x1161
local JAMO_V_LAST = 0x1175
local JAMO_T_FIRST = 0x11A8
local JAMO_T_LAST = 0x11C2

local DATA = nil

local function data()
  if not DATA then
    DATA = require('jump.unicode_data')
  end

  return DATA
end

-- Decode the code point starting at the 1-based byte offset `i`, together with
-- its byte length.
local function decode(str, i)
  local byte = str:byte(i)

  if byte < 0x80 then
    return byte, 1
  end

  local len = text.utf8_len(str, i)
  local b1 = str:byte(i + 1) - 0x80

  if len == 2 then
    return (byte - 0xC0) * 0x40 + b1, 2
  end

  local b2 = str:byte(i + 2) - 0x80

  if len == 3 then
    return (byte - 0xE0) * 0x1000 + b1 * 0x40 + b2, 3
  end

  return (byte - 0xF0) * 0x40000
    + b1 * 0x1000
    + b2 * 0x40
    + (str:byte(i + 3) - 0x80),
    4
end

-- Encode a code point as UTF-8.
local function encode(cp)
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

-- Compose `cp` onto the preceding code point `base`, if Unicode defines a
-- composed character for that pair. Hangul is handled separately because it is
-- composed arithmetically rather than from a table.
local function compose(base, cp)
  if
    base >= JAMO_L_FIRST
    and base <= JAMO_L_LAST
    and cp >= JAMO_V_FIRST
    and cp <= JAMO_V_LAST
  then
    return HANGUL_FIRST + (base - JAMO_L_FIRST) * 588 + (cp - JAMO_V_FIRST) * 28
  end

  if
    base >= HANGUL_FIRST
    and base <= HANGUL_LAST
    and (base - HANGUL_FIRST) % 28 == 0
    and cp >= JAMO_T_FIRST
    and cp <= JAMO_T_LAST
  then
    return base + (cp - JAMO_T_FIRST) + 1
  end

  local marks = data().compose[base]

  return marks and marks[cp]
end

-- Whether `str` is worth normalizing at all. Every non-ASCII character may be
-- followed by a combining mark (they exist for most scripts, not just Latin),
-- so the cheap check is simply "contains a non-ASCII byte". ASCII keeps the
-- common case free of the table load.
function M.needed(str)
  return str:find('[\128-\255]') ~= nil
end

-- Put every run of combining marks into canonical order (stable sort by
-- combining class). Marks with class 0 are starters and delimit the runs.
local function reorder(cps)
  local ccc = data().ccc

  for i = 2, #cps do
    local mark = cps[i]
    local cc = ccc[mark]

    if cc and cc ~= 0 then
      local j = i

      while j > 1 do
        local prev = ccc[cps[j - 1]] or 0

        if prev == 0 or prev <= ccc[cps[j]] then
          break
        end

        cps[j - 1], cps[j] = cps[j], cps[j - 1]
        j = j - 1
      end
    end
  end
end

-- Return the NFC composition of `str`.
function M.normalize(str)
  local cps = {}
  local i = 1

  while i <= #str do
    local cp, len = decode(str, i)
    i = i + len
    cps[#cps + 1] = cp
  end

  reorder(cps)

  local ccc = data().ccc
  local out = {}
  -- Index into `out` of the last starter: marks compose onto it.
  local starter = nil
  -- Combining class of the last mark that did not compose. A following mark is
  -- blocked from the starter when it does not have a higher class (UAX #15).
  local last_cc = 0

  for _, cp in ipairs(cps) do
    local cc = ccc[cp] or 0
    local composed = nil

    if cc == 0 then
      composed = starter and compose(out[starter], cp)
    elseif starter and last_cc < cc then
      composed = compose(out[starter], cp)
    end

    if composed then
      out[starter] = composed
    else
      out[#out + 1] = cp

      if cc == 0 then
        starter = #out
        last_cc = 0
      else
        last_cc = cc
      end
    end
  end

  local encoded = {}

  for j = 1, #out do
    encoded[j] = encode(out[j])
  end

  return table.concat(encoded)
end

return M
