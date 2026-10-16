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
}

local function search(pattern, lines, start_line, matches)
  local lower = pattern == pattern:lower()

  for idx, line in ipairs(lines) do
    local lnum = start_line + idx - 1
    local line = lower and line:lower() or line

    if #line > 0 then
      local col = 1

      while true do
        local start, stop = line:find(pattern, col, true)

        if not start then
          break
        end

        col = stop + 1
        table.insert(matches, {
          line = lnum - 1,
          start_col = start - 1,
          end_col = stop,
          line_index = idx,
        })
      end
    end
  end
end

local function available_labels(lines, matches)
  local avail = {}

  for _, char in ipairs(LABELS) do
    avail[char] = true
  end

  -- Disable all the labels that conflict with any of the characters that may be
  -- matched by the next input.
  for _, match in ipairs(matches) do
    local next_col = match.end_col + 1
    local next_char = lines[match.line_index]:sub(next_col, next_col):lower()

    avail[next_char] = false
  end

  return avail
end

-- Width (in screen cells) of inline virtual text anchored at the exact byte
-- position `col` on `line`, across all namespaces. Inline virtual text is drawn
-- before the character it is anchored to, shifting that character to the right
-- by this width. `virt_text_pos = "overlay"` does not account for it, so a label
-- anchored there would land on the inline text instead of the matched character.
local function inline_offset(buf, line, col)
  local offset = 0
  local marks = api.nvim_buf_get_extmarks(buf, -1, { line, col }, { line, col }, { details = true })

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

function M.start()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local info = fn.getwininfo(win)[1]
  local top = info.topline
  local bot = info.botline
  local lines = api.nvim_buf_get_lines(buf, top - 1, bot, true)
  local chars = ''
  local matches = {}
  local active = {}

  while true do
    local char = fn.getcharstr(-1)
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
        vim.cmd("normal! m'")
        api.nvim_win_set_cursor(win, jump_to)
      end

      break
    elseif char == BS or char == CTRL_H then
      chars = chars:sub(1, #chars - 1)
    elseif jump_to then
      vim.cmd("normal! m'")
      api.nvim_win_set_cursor(win, jump_to)
      break
    else
      chars = chars .. char
    end

    matches = {}
    active = {}
    api.nvim_buf_clear_namespace(buf, NS, 0, -1)

    if #chars > 0 then
      search(chars, lines, top, matches)

      local avail = available_labels(lines, matches)

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
          buf,
          NS,
          CONFIG.search,
          { match.line, match.start_col },
          { match.line, match.end_col },
          { priority = 200 }
        )

        if label then
          active[label] = { match.line + 1, match.start_col }

          local offset = inline_offset(buf, match.line, match.start_col)
          local opts = {
            virt_text = { { label, CONFIG.label } },
            priority = 201,
          }

          -- Shift the label past any inline virtual text anchored at the
          -- match, otherwise it covers that text instead of the character.
          if offset > 0 then
            opts.virt_text_win_col = match.start_col + offset
          else
            opts.virt_text_pos = 'overlay'
          end

          api.nvim_buf_set_extmark(buf, NS, match.line, match.start_col, opts)
        end
      end
    end

    vim.cmd.redraw()
  end

  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  vim.cmd.redraw()
end

function M.setup(opts)
  if opts then
    CONFIG = vim.tbl_extend('force', CONFIG, opts)
  end

  LABELS = fn.split(CONFIG.labels, '\\zs')
end

M.setup()

return M
