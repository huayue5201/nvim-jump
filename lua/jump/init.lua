local fn = vim.fn
local api = vim.api

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
}

-- Byte length of the UTF-8 character starting at the 1-based byte index `i`.
local function utf8_len(str, i)
  local byte = str:byte(i)

  if byte < 0x80 then
    return 1
  elseif byte < 0xE0 then
    return 2
  elseif byte < 0xF0 then
    return 3
  end

  return 4
end

-- Split a string into its UTF-8 characters.
local function char_list(str)
  local chars = {}
  local i = 1

  while i <= #str do
    local len = utf8_len(str, i)

    chars[#chars + 1] = str:sub(i, i + len - 1)
    i = i + len
  end

  return chars
end

local PINYIN = nil

-- Character -> pinyin initials. Loaded lazily so buffers without CJK text
-- never pay for it.
local function pinyin()
  if PINYIN then
    return PINYIN
  end

  local groups = require('jump.pinyin')
  local map = {}

  for letter, chars in pairs(groups) do
    for _, char in ipairs(char_list(chars)) do
      local cur = map[char]

      if cur then
        if not cur:find(letter, 1, true) then
          map[char] = cur .. letter
        end
      else
        map[char] = letter
      end
    end
  end

  PINYIN = map
  return map
end

-- Pinyin initials of `char`, or nil when it is not a CJK character we know.
local function pinyin_key(char)
  if char:byte() < 0x80 then
    return nil
  end

  return pinyin()[char]
end

-- Does the character `entry` match the input character `char`?
--
-- ASCII is matched literally (case-insensitively when the input has no
-- capitals), CJK characters match through their pinyin initials and can still
-- be matched by typing the character itself, everything else is literal.
local function key_hit(entry, char, sensitive)
  if entry.py then
    if #char > 1 then
      return entry.lit == char
    end

    -- Pinyin initials have no case, so they always match case-insensitively.
    return entry.py:find(char:lower(), 1, true) ~= nil
  end

  if #entry.lit == 1 and entry.lit:byte() < 0x80 then
    if sensitive then
      return entry.lit == char
    end

    return entry.lit:lower() == char:lower()
  end

  return entry.lit == char
end

-- Turn a line into its characters, remembering each one's byte range (0-based,
-- end exclusive), its literal text and its pinyin initials (if any).
local function parse_line(line)
  local chars = {}
  local i = 1

  while i <= #line do
    local len = utf8_len(line, i)
    local char = line:sub(i, i + len - 1)

    chars[#chars + 1] = {
      start = i - 1,
      stop = i - 1 + len,
      lit = char,
      py = pinyin_key(char),
    }
    i = i + len
  end

  return chars
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

local function search(pattern, panels, matches)
  local sensitive = pattern ~= pattern:lower()
  local pchars = char_list(pattern)
  local plen = #pchars

  if plen == 0 then
    return
  end

  for _, panel in ipairs(panels) do
    for idx, chars in ipairs(panel.parsed) do
      local lnum = panel.top + idx - 1

      for i = 1, #chars - plen + 1 do
        local hit = true

        for j = 1, plen do
          if not key_hit(chars[i + j - 1], pchars[j], sensitive) then
            hit = false
            break
          end
        end

        if hit then
          local first = chars[i]
          local last = chars[i + plen - 1]
          local next_char = chars[i + plen]

          matches[#matches + 1] = {
            line = lnum - 1,
            start_col = first.start,
            end_col = last.stop,
            -- Cached because matches from different windows may have different
            -- text, and to avoid fetching the line again for the label.
            text = panel.lines[idx],
            win = panel.win,
            buf = panel.buf,
            next_lit = next_char and next_char.lit or nil,
            next_py = next_char and next_char.py or nil,
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

  -- Disable all the labels that conflict with any of the characters that may be
  -- matched by the next input. A CJK character may be reached through several
  -- pinyin initials, so all of them are disabled.
  for _, match in ipairs(matches) do
    if match.next_py then
      for _, char in ipairs(char_list(match.next_py)) do
        avail[char:lower()] = false
      end
    elseif match.next_lit then
      avail[match.next_lit:lower()] = false
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
  -- The end position is exclusive, so `col + 1` also includes marks anchored
  -- exactly at `col`.
  local marks = api.nvim_buf_get_extmarks(
    buf,
    -1,
    { line, 0 },
    { line, col + 1 },
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
  local matches = {}
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
      for _, char in ipairs(LABELS) do
        jump_to = active[char]

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
end

M.setup()

return M
