-- Extensible character matching.
--
-- A codec teaches `jump` how to match a character that is not plain ASCII. It
-- is a module returning one or more of:
--
--   keys(char) -> string[] | nil
--     Alternative ASCII keys that may be typed instead of the character, e.g.
--     '你' -> { 'n' } or 'き' -> { 'ki' }. A character with several readings may
--     return several keys (e.g. a 多音字 like '行' -> { 'x', 'h' }). Keys are
--     case-insensitive. Returning nil (or an empty list) means "no alternative":
--     the character can still be typed literally.
--
--   parse(line, entries) -> entry[] | nil
--     Optional line-level transform for context-sensitive scripts (e.g.
--     Japanese kana, where a small kana modifies the preceding one). It gets
--     the whole line and the entries built so far (one per character by
--     default) and returns a replacement list, each entry being
--     { start, stop, lit, keys } with 0-based byte offsets and an exclusive
--     `stop`. Returning nil leaves the entries unchanged. Every enabled codec
--     runs in configuration order, so several line-level codecs can cooperate
--     (e.g. one fusing kana, another annotating hanzi).
--     Entries are matched in order, so when a codec fuses several characters
--     into one entry, that entry can be reached through its ASCII keys but not
--     by typing the fused characters literally (the query is split per
--     character, it is never passed through `parse`).
--
--   normalize(str) -> string | nil
--     Optional text folding applied to the whole input query before it is split
--     into characters, e.g. to turn compatibility forms (half-width katakana,
--     CJK compatibility ideographs) into their canonical ones. Canonical (NFC)
--     composition is applied by `jump` itself, so a codec only needs this for
--     compatibility mappings. Returning nil leaves the query unchanged.
--
-- Codecs are loaded lazily by name (see CONFIG.codecs in lua/jump/init.lua), so
-- a codec's tables do not cost anything until it is enabled.

local M = {}

-- Enabled codecs, in configuration order.
local ACTIVE = {}

local EMPTY = {}

-- Enable the codec module `jump.codec.<name>`.
function M.load(name)
  local ok, mod = pcall(require, 'jump.codec.' .. name)

  if not ok then
    error(string.format("jump: unable to load codec '%s': %s", name, mod), 0)
  end

  ACTIVE[#ACTIVE + 1] = mod
end

-- Drop all enabled codecs (used by `setup`, which reloads them from config).
function M.reset()
  ACTIVE = {}
end

-- Every alternative key for `char`, merged across the enabled codecs.
function M.keys(char)
  local keys = nil

  for _, mod in ipairs(ACTIVE) do
    local got = mod.keys and mod.keys(char)

    if got and #got > 0 then
      keys = keys or {}

      for _, key in ipairs(got) do
        keys[#keys + 1] = key
      end
    end
  end

  return keys or EMPTY
end

-- Turn the default per-character entries into the final ones by running every
-- enabled line-level codec in configuration order.
function M.parse(line, fallback)
  local entries = fallback(line)

  for _, mod in ipairs(ACTIVE) do
    if mod.parse then
      local got = mod.parse(line, entries)

      if got then
        entries = got
      end
    end
  end

  return entries
end

-- Normalize an input query: canonical (NFC) composition followed by each
-- codec's compatibility folding. Only the query needs this; buffer text is
-- assumed to be NFC already (that is what editors and IMEs write), and
-- normalizing it would invalidate the byte offsets we highlight with.
function M.normalize(str)
  for _, mod in ipairs(ACTIVE) do
    if mod.normalize then
      local got = mod.normalize(str)

      if got then
        str = got
      end
    end
  end

  local unicode = require('jump.unicode')

  if unicode.needed(str) then
    return unicode.normalize(str)
  end

  return str
end

return M
