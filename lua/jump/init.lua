local fn = vim.fn
local api = vim.api

local text = require('jump.text')
local codec = require('jump.codec')

local M = {}
local NS = api.nvim_create_namespace('jump')
local CR = api.nvim_replace_termcodes('<Cr>', true, true, true)
local BS = api.nvim_replace_termcodes('<Bs>', true, true, true)
local CTRL_H = api.nvim_replace_termcodes('<C-h>', true, true, true)
local ESC = api.nvim_replace_termcodes('<Esc>', true, true, true)
local LABELS = {}
local CONFIG = {
  -- The labels that may be used, in order of their preference.
  labels = 'fdsaghjklrewqtyuiopvcxzbnm',

  -- The highlight group to use for match highlights.
  search = 'Search',

  -- The highlight group to use for labels.
  label = 'FlashLabel',

  -- Jump to matches in every window of the current tab page instead of only
  -- the current window. Floating windows (popups, hover, …) are never included.
  multi_window = false,

  -- Character codecs, in order of registration. A codec maps non-ASCII
  -- characters to alternative ASCII keys (e.g. pinyin initials); see
  -- lua/jump/codec/init.lua. Add your own under lua/jump/codec/<name>.lua and
  -- list it here.
  codecs = { 'pinyin' },
}

-- Default line parser: one entry per character, with the keys supplied by the
-- enabled codecs. A line-level codec can bypass this (see lua/jump/codec).
local function default_parse_line(line)
  local chars = {}
  local i = 1

  while i <= #line do
    local len = text.utf8_len(line, i)
    local char = line:sub(i, i + len - 1)

    chars[#chars + 1] = {
      start = i - 1,
      stop = i - 1 + len,
      lit = char,
      keys = codec.keys(char),
    }
    i = i + len
  end

  return chars
end

-- Turn a line into its characters, remembering each one's byte range (0-based,
-- end exclusive), its literal text and the alternative keys that may match it.
local function parse_line(line)
  return codec.parse(line, default_parse_line)
end

-- The windows that take part in a jump: the current one, or (with
-- `multi_window`) every non-floating window of the current tab page.
local function target_windows(cur_win)
  if not CONFIG.multi_window then
    return { cur_win }
  end

  local wins = {}

  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    -- The current window is always searched, even if it is floating.
    if win == cur_win or api.nvim_win_get_config(win).relative == '' then
      wins[#wins + 1] = win
    end
  end

  return wins
end

-- Snapshot one window: its visible lines and their parsed keys. The text does
-- not change while we are jumping, so parsing it only once is enough.
local function window_panel(win)
  local buf = api.nvim_win_get_buf(win)
  local info = fn.getwininfo(win)[1]
  local top = info.topline
  local bot = info.botline
  local lines = api.nvim_buf_get_lines(buf, top - 1, bot, true)
  local parsed = {}

  for idx, line in ipairs(lines) do
    parsed[idx] = parse_line(line)
  end

  return { win = win, buf = buf, top = top, lines = lines, parsed = parsed }
end

local function clear_panels(panels)
  for _, panel in ipairs(panels) do
    api.nvim_buf_clear_namespace(panel.buf, NS, 0, -1)
  end
end

-- Mark the old position in the jumplist, then switch to the window holding the
-- match (if it is not the current one) and move the cursor there.
local function jump(target)
  vim.cmd("normal! m'")
  api.nvim_set_current_win(target.win)
  api.nvim_win_set_cursor(target.win, target.pos)
end

-- Match one of the entry's keys against the query starting at `qi`.
--
-- Keys are ASCII and always case-insensitive (pinyin and romanizations have no
-- case). A key may be longer than what is left of the query: the query then
-- ends in the middle of the key, which is a valid prefix match. Returns the
-- number of query characters consumed, or nil.
local function key_hit(key, pchars, qi)
  local avail = #pchars - qi + 1

  if avail <= 0 then
    return nil
  end

  local n = math.min(avail, #key)

  for j = 1, n do
    local q = pchars[qi + j - 1]

    if #q ~= 1 or q:lower() ~= key:sub(j, j) then
      return nil
    end
  end

  return n
end

-- Match the literal character (used when the input types the character itself).
-- ASCII follows the query's case sensitivity, everything else is exact.
local function literal_hit(entry, pchars, qi, sensitive)
  local q = pchars[qi]

  if not q then
    return nil
  end

  if #entry.lit == 1 and entry.lit:byte() < 0x80 then
    if sensitive then
      return entry.lit == q and 1 or nil
    end

    return entry.lit:lower() == q:lower() and 1 or nil
  end

  return entry.lit == q and 1 or nil
end

-- Try to consume the whole query starting at `start`, walking forward through
-- the parsed characters. Returns the index of the last consumed character and,
-- when the query ended in the middle of one of its alternative keys, the set of
-- characters that would extend one of these matches (nil otherwise). The set
-- matters because those key presses extend the match rather than jump to a
-- label. The longest completion wins: with multi-character keys a query can
-- often be split in more than one way, and the user expects the widest span.
-- Branches are kept in a stack instead of recursing: a long line would
-- otherwise exceed Lua's C stack limit. Each state is expanded once, so
-- ambiguous keys cannot make the search exponential.
local function match_from(parsed, start, pchars, sensitive)
  local pending = { { start, 1 } }
  local seen = {}
  local best = nil
  local reserved = nil

  while #pending > 0 do
    local state = table.remove(pending)
    local i = state[1]
    local qi = state[2]
    local rest = state[3]

    if qi > #pchars then
      local last = i - 1

      if not best or last > best then
        best = last
        reserved = nil
      end

      if last == best and rest then
        reserved = reserved or {}
        reserved[rest:sub(1, 1):lower()] = true
      end
    else
      local entry = parsed[i]

      if entry then
        local row = seen[i]

        if not row then
          row = {}
          seen[i] = row
        end

        local key = qi .. ':' .. (rest or '')

        if not row[key] then
          row[key] = true

          for _, alt in ipairs(entry.keys) do
            local n = key_hit(alt, pchars, qi)

            if n then
              local left = alt:sub(n + 1)

              pending[#pending + 1] = {
                i + 1,
                qi + n,
                left ~= '' and left or nil,
              }
            end
          end

          local n = literal_hit(entry, pchars, qi, sensitive)

          if n then
            pending[#pending + 1] = { i + 1, qi + n }
          end
        end
      end
    end
  end

  return best, reserved
end

local function search(pattern, panels, matches)
  local sensitive = pattern ~= pattern:lower()
  -- Normalize before splitting: input methods may produce decomposed text, and
  -- equivalent forms must compare equal (see lua/jump/unicode.lua).
  local pchars = text.chars(codec.normalize(pattern))

  if #pchars == 0 then
    return
  end

  for _, panel in ipairs(panels) do
    for idx, chars in ipairs(panel.parsed) do
      local lnum = panel.top + idx - 1

      for start = 1, #chars do
        local last, reserved = match_from(chars, start, pchars, sensitive)

        if last then
          local first = chars[start]
          local last_char = chars[last]

          matches[#matches + 1] = {
            line = lnum - 1,
            start_col = first.start,
            end_col = last_char.stop,
            -- Cached because matches from different windows may have different
            -- text, and to avoid fetching the line again for the label.
            text = panel.lines[idx],
            win = panel.win,
            buf = panel.buf,
            next = chars[last + 1],
            reserved = reserved,
          }
        end
      end
    end
  end
end

local function available_labels(matches)
  local avail = {}

  for _, char in ipairs(LABELS) do
    avail[char] = true
  end

  -- Disable all the labels that conflict with a character the user may type
  -- next: the first letter of every alternative key, and an ASCII literal.
  -- A codec may give a character several keys (多音字), so all of them count.
  for _, match in ipairs(matches) do
    local next_entry = match.next

    if next_entry then
      for _, key in ipairs(next_entry.keys) do
        avail[key:sub(1, 1):lower()] = false
      end

      if #next_entry.lit == 1 and next_entry.lit:byte() < 0x80 then
        avail[next_entry.lit:lower()] = false
      end
    end

    -- The query may also have stopped in the middle of one or more
    -- multi-character keys; those next characters would extend the match
    -- instead of jumping to a label.
    if match.reserved then
      for char in pairs(match.reserved) do
        avail[char] = false
      end
    end
  end

  return avail
end

-- Width (in screen cells) of inline virtual text anchored at byte positions
-- `0..col` on `line`, across all namespaces. Inline virtual text is drawn
-- before the character it is anchored to, shifting everything after it to the
-- right by its width. `virt_text_pos = "overlay"` does not account for any of
-- this, so a label that switches to `virt_text_win_col` must add the total width
-- of *every* inline hint at or before `col` (not just one anchored exactly at
-- `col`), otherwise the label lands to the left of the matched character.
local function inline_offset(buf, line, col)
  local offset = 0
  -- Extmark regions are inclusive, so ending the range at `col` covers exactly
  -- the hints anchored at or before the match start. Hints right after it only
  -- shift later characters, not the label.
  local marks = api.nvim_buf_get_extmarks(
    buf,
    -1,
    { line, 0 },
    { line, col },
    { details = true }
  )

  for _, mark in ipairs(marks) do
    local details = mark[4]

    if details.virt_text_pos == 'inline' and details.virt_text then
      for _, chunk in ipairs(details.virt_text) do
        offset = offset + fn.strdisplaywidth(chunk[1])
      end
    end
  end

  return offset
end

-- Async LSP errors (e.g. gopls cancelling an inlay hint request) are delivered
-- while we are blocked waiting for input, and Neovim turns them into a Lua
-- error that would abort the jump. Swallow them and keep waiting for a key.
local function wait_for_char()
  local ok, char = pcall(fn.getcharstr, -1)

  if not ok then
    return nil
  end

  return char
end

function M.start()
  local panels = {}

  -- Parse every participating window's lines once.
  for _, win in ipairs(target_windows(api.nvim_get_current_win())) do
    panels[#panels + 1] = window_panel(win)
  end

  local chars = ''
  local matches
  local active = {}

  while true do
    local char

    repeat
      char = wait_for_char()
    until char ~= nil

    local jump_to = active[char]

    if char == ESC then
      break
    elseif char == CR then
      for _, label in ipairs(LABELS) do
        jump_to = active[label]

        if jump_to then
          break
        end
      end

      if jump_to then
        jump(jump_to)
      end

      break
    elseif char == BS or char == CTRL_H then
      -- Delete one character instead of one byte, otherwise a multi-byte
      -- character (e.g. a CJK one) is split into invalid UTF-8.
      chars = fn.strcharpart(chars, 0, math.max(fn.strchars(chars) - 1, 0))
    elseif jump_to then
      jump(jump_to)
      break
    else
      chars = chars .. char
    end

    matches = {}
    active = {}
    clear_panels(panels)

    if #chars > 0 then
      search(chars, panels, matches)

      local avail = available_labels(matches)

      for _, match in ipairs(matches) do
        local label = nil

        for _, cur in ipairs(LABELS) do
          if avail[cur] then
            label = cur
            avail[cur] = false
            break
          end
        end

        vim.hl.range(
          match.buf,
          NS,
          CONFIG.search,
          { match.line, match.start_col },
          { match.line, match.end_col },
          { priority = 200 }
        )

        if label then
          active[label] = {
            win = match.win,
            pos = { match.line + 1, match.start_col },
          }

          local offset = inline_offset(match.buf, match.line, match.start_col)
          local opts = {
            virt_text = { { label, CONFIG.label } },
            priority = 201,
          }

          -- Shift the label past any inline virtual text anchored at or
          -- before the match, otherwise it lands left of the character.
          if offset > 0 then
            -- `virt_text_win_col` is a display column, not a byte offset, so
            -- convert the byte position to its display width (a CJK character
            -- is three bytes but two cells wide).
            local prefix = match.text:sub(1, match.start_col)

            opts.virt_text_win_col = fn.strdisplaywidth(prefix) + offset
          else
            opts.virt_text_pos = 'overlay'
          end

          api.nvim_buf_set_extmark(
            match.buf,
            NS,
            match.line,
            match.start_col,
            opts
          )
        end
      end
    end

    -- Redraw also pumps the event loop, so guard it the same way.
    pcall(vim.cmd.redraw)
  end

  clear_panels(panels)
  pcall(vim.cmd.redraw)
end

function M.setup(opts)
  if opts then
    CONFIG = vim.tbl_extend('force', CONFIG, opts)
  end

  LABELS = fn.split(CONFIG.labels, '\\zs')

  codec.reset()

  for _, name in ipairs(CONFIG.codecs) do
    codec.load(name)
  end
end

M.setup()

return M
