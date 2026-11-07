-- Headless test suite. Run from the repository root with:
--
--   nvim --headless --clean -l tests/run.lua
--
-- Exits with a non-zero status when a test fails.

local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.runtimepath:prepend(root)

local api = vim.api

local failures = 0
local total = 0

local function test(name, fn)
  total = total + 1

  local ok, err = pcall(fn)

  if ok then
    io.write('ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.write('FAIL ' .. name .. '\n     ' .. tostring(err) .. '\n')
  end
end

local function eq(got, want, what)
  if not vim.deep_equal(got, want) then
    error(
      string.format(
        '%s: expected %s, got %s',
        what or 'value',
        vim.inspect(want),
        vim.inspect(got)
      ),
      2
    )
  end
end

local function ok(value, what)
  if not value then
    error((what or 'assertion') .. ' failed', 2)
  end
end

-- Upvalues are how the tests reach functions that are not part of the module's
-- public API.
local function ups(f)
  local t, i = {}, 1

  while true do
    local name, value = debug.getupvalue(f, i)

    if not name then
      return t
    end

    t[name] = value
    i = i + 1
  end
end

local jump = require('jump')
local codec = require('jump.codec')
local text = require('jump.text')
local unicode = require('jump.unicode')

local start_ups = ups(jump.start)
local search = assert(start_ups.search, 'search')
local available_labels = assert(start_ups.available_labels, 'available_labels')
local target_windows = assert(start_ups.target_windows, 'target_windows')
local inline_offset = assert(start_ups.inline_offset, 'inline_offset')
local parse_line = assert(ups(start_ups.window_panel).parse_line, 'parse_line')

-- Build the panels `search` expects from plain lines.
local function panels(...)
  local out = {}

  for i, line in ipairs({ ... }) do
    out[i] = {
      win = i,
      buf = i,
      top = i * 10 - 9,
      lines = { line },
      parsed = { parse_line(line) },
    }
  end

  return out
end

local function matches(pattern)
  local found = {}
  search(pattern, panels('abc你好世界'), found)
  return found
end

local function normalize_setup()
  jump.setup({ codecs = { 'pinyin' }, multi_window = false })
end

normalize_setup()

test('text: utf8 lengths and characters', function()
  eq(text.utf8_len('a', 1), 1)
  eq(text.utf8_len('é', 1), 2)
  eq(text.utf8_len('你', 1), 3)
  eq(text.utf8_len('😀', 1), 4)
  eq(text.chars('a你😀'), { 'a', '你', '😀' })
  eq(text.chars(''), {})
end)

test('codec: pinyin keys, ASCII has none', function()
  eq(codec.keys('你'), { 'n' })
  eq(codec.keys('a'), {})
  eq(codec.keys('x'), {})
end)

test('codec: parse_line byte ranges and keys', function()
  local entries = parse_line('a你好')
  eq(#entries, 3)
  eq({ entries[1].start, entries[1].stop, entries[1].lit }, { 0, 1, 'a' })
  eq({ entries[2].start, entries[2].stop, entries[2].lit }, { 1, 4, '你' })
  eq({ entries[3].start, entries[3].stop, entries[3].lit }, { 4, 7, '好' })
  eq(entries[2].keys, { 'n' })
  eq(entries[3].keys, { 'h' })
end)

test('search: pinyin, literal and mixed queries', function()
  local found = matches('nh')
  eq(#found, 1)
  eq({ found[1].start_col, found[1].end_col }, { 3, 9 })
  eq(found[1].next.lit, '世')

  found = matches('nhsj')
  eq(#found, 1)
  eq(found[1].end_col, 15)

  found = matches('c你')
  eq(#found, 1)
  eq({ found[1].start_col, found[1].end_col }, { 2, 6 })

  eq(#matches('zzz'), 0)
end)

test('search: case sensitivity follows the query', function()
  local found = {}
  search('N', panels('你好'), found)
  eq(#found, 1, 'pinyin keys are case-insensitive')

  found = {}
  search('A', panels('abc'), found)
  eq(#found, 0, 'capital ASCII is case-sensitive')

  found = {}
  search('a', panels('Abc'), found)
  eq(#found, 1, 'lowercase ASCII ignores case')
end)

test('search: absolute line numbers come from the panel top', function()
  local found = {}
  local p = panels('aaa', 'bbb', 'ccc')
  search('b', p, found)
  eq(#found, 3, 'one match per character')
  eq(found[1].line, 10)
  eq(found[1].win, 2)
  eq(found[1].buf, 2)
end)

test('search: the longest match wins', function()
  -- The short key completes first while walking forward, the long one spans more
  -- characters. The user expects the wider span.
  package.preload['jump.codec.long'] = function()
    return {
      parse = function()
        return {
          { start = 0, stop = 1, lit = '', keys = { 'a', 'ab' } },
          { start = 1, stop = 2, lit = 'b', keys = {} },
        }
      end,
    }
  end

  jump.setup({ codecs = { 'long' } })
  local found = {}
  search('ab', panels('ab'), found)
  eq(#found, 1)
  eq(
    { found[1].start_col, found[1].end_col },
    { 0, 2 },
    'the wider span must win'
  )
  eq(found[1].reserved, nil, 'a complete match reserves nothing')
  jump.setup({ codecs = { 'pinyin' } })
end)

test('search: ambiguous keys do not explode the state space', function()
  -- Every character may consume one or two query characters. Without a visited
  -- set this is 2^22 paths; with one it is a few hundred states.
  local n = 22
  package.preload['jump.codec.amb'] = function()
    return {
      parse = function()
        local entries = {}

        for i = 1, n do
          entries[i] = {
            start = i - 1,
            stop = i,
            lit = '',
            keys = { 'a', 'aa' },
          }
        end

        return entries
      end,
    }
  end

  jump.setup({ codecs = { 'amb' } })
  local found = {}
  search(string.rep('a', n), panels('x'), found)
  jump.setup({ codecs = { 'pinyin' } })
  eq(#found > 0, true)
  eq(found[1].end_col, n, 'the whole line is consumed')
end)

test('search: normalizes decomposed query text', function()
  local combining_acute = '\204\129'
  local found = {}
  search('cafe' .. combining_acute, panels('café'), found)
  eq(#found, 1, 'e + U+0301 must match é')
end)

test('available_labels: next key and literal', function()
  local av = available_labels({ { next = { keys = { 'n' }, lit = '你' } } })
  eq(av.n, false, 'first letter of a next key is disabled')

  av = available_labels({ { next = { keys = {}, lit = 'b' } } })
  eq(av.b, false, 'ASCII next literal is disabled')

  av = available_labels({ { next = { keys = { 'h', 'x' }, lit = '' } } })
  eq(av.h, false)
  eq(av.x, false)

  av = available_labels({ { next = nil } })
  eq(av.f, true, 'labels stay available without a next character')
end)

test('available_labels: mid-key continuation is disabled', function()
  package.preload['jump.codec.kya'] = function()
    return {
      parse = function(line)
        if not line:find('き', 1, true) then
          return nil
        end

        local entries = {}

        for i = 1, select(2, line:gsub('き', '')) do
          entries[#entries + 1] = {
            start = (i - 1) * 3,
            stop = i * 3,
            lit = 'き',
            keys = { 'kya' },
          }
        end

        return entries
      end,
    }
  end

  jump.setup({ codecs = { 'kya' } })
  local found = {}
  search('ky', panels('きききき'), found)
  eq(#found, 4)
  eq(found[1].reserved, { a = true }, 'the unconsumed key suffix is recorded')

  local av = available_labels(found)
  eq(av.a, false, 'the key suffix must not be usable as a label')
  eq(av.k, false)

  jump.setup({ codecs = { 'pinyin' } })
end)

test('codec: several line-level codecs cooperate', function()
  package.preload['jump.codec.one'] = function()
    return {
      parse = function(_, entries)
        for _, entry in ipairs(entries) do
          if entry.lit == 'あ' then
            entry.keys = { 'a' }
          end
        end

        return entries
      end,
    }
  end

  package.preload['jump.codec.two'] = function()
    return {
      parse = function(_, entries)
        for _, entry in ipairs(entries) do
          if entry.lit == 'あ' then
            entry.keys[#entry.keys + 1] = 'x'
          end
        end

        return entries
      end,
    }
  end

  jump.setup({ codecs = { 'one', 'two' } })
  eq(parse_line('あ')[1].keys, { 'a', 'x' }, 'both codecs ran, in order')
  jump.setup({ codecs = { 'pinyin' } })
end)

test('codec: pinyin overrides add the hidden readings', function()
  eq(codec.keys('行'), { 'x', 'h' })
  eq(codec.keys('长'), { 'c', 'z' })
  eq(codec.keys('咯'), { 'k', 'l', 'g' })

  local found = {}
  search('h', panels('行'), found)
  eq(#found, 1, 'háng is reachable through h')

  found = {}
  search('x', panels('行'), found)
  eq(#found, 1)
end)

test('normalize: canonical composition', function()
  eq(unicode.normalize('e\204\129'), vim.fn.list2str({ 0xE9 }), 'e + acute')
  eq(unicode.normalize('A\204\138'), vim.fn.list2str({ 0xC5 }), 'A + ring')
  eq(
    unicode.normalize('a\204\138\204\129'),
    vim.fn.list2str({ 0x1FB }),
    'chained marks'
  )
  eq(
    unicode.normalize('\227\129\139\227\130\153'),
    vim.fn.list2str({ 0x304C }),
    'か + U+3099 = が'
  )
  eq(unicode.normalize('abc'), 'abc')
  eq(unicode.needed('abc'), false)
  eq(unicode.needed('e\204\129'), true)
  eq(unicode.needed('你'), true)
end)

test('normalize: marks are put into canonical order', function()
  local dot_below = '\204\163' -- U+0323, class 220
  local acute = '\204\129' -- U+0301, class 230
  local want = vim.fn.list2str({ 0x1EA1, 0x301 })

  eq(unicode.normalize('a' .. dot_below .. acute), want, 'dot below first')
  eq(
    unicode.normalize('a' .. acute .. dot_below),
    want,
    'the other input order gives the same NFC'
  )

  -- U+0334 (class 1) must move behind U+0301 before composing, but it then
  -- blocks nothing: the acute still composes with the base.
  eq(
    unicode.normalize('a\204\180\204\129'),
    vim.fn.list2str({ 0xE1, 0x334 }),
    'canonical order then composition'
  )
end)

test('normalize: Hangul jamo', function()
  local jamo = vim.fn.list2str({ 0x1112, 0x1161, 0x11AB })
  eq(
    unicode.normalize(jamo),
    vim.fn.list2str({ 0xD55C }),
    'ᄒ + ᅡ + ᆫ = 한'
  )

  local lv = vim.fn.list2str({ 0x1100, 0x1161 })
  eq(unicode.normalize(lv), vim.fn.list2str({ 0xAC00 }), 'ᄀ + ᅡ = 가')
end)

test('codec: normalize hook is applied to the query', function()
  package.preload['jump.codec.wide'] = function()
    return {
      normalize = function(str)
        return (str:gsub('\239\189\182', 'カ')) -- half-width ｶ -> full-width カ
      end,
    }
  end

  jump.setup({ codecs = { 'wide' } })
  local found = {}
  search('ｶ', panels('カ'), found)
  eq(#found, 1, 'codec.normalize must fold the query')
  jump.setup({ codecs = { 'pinyin' } })
end)

test('setup: disabling a codec stops alternative matching', function()
  jump.setup({ codecs = {} })
  local found = {}
  search('nh', panels('你好'), found)
  eq(#found, 0, 'no codec, no pinyin match')

  found = {}
  search('你', panels('你好'), found)
  eq(#found, 1, 'literal matching still works')

  jump.setup({ codecs = { 'pinyin' } })
end)

test('setup: an unknown codec raises a clear error', function()
  local ok_call, err = pcall(jump.setup, { codecs = { 'no-such-codec' } })
  eq(ok_call, false)
  ok(
    tostring(err):find("unable to load codec 'no-such-codec'", 1, true),
    tostring(err)
  )
  jump.setup({ codecs = { 'pinyin' } })
end)

test('multi_window: floating windows are skipped', function()
  local buf1 = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf1, 0, -1, false, { 'aaa' })
  api.nvim_win_set_buf(0, buf1)
  local win1 = api.nvim_get_current_win()

  vim.cmd('split')
  local buf2 = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf2, 0, -1, false, { 'bbb' })
  api.nvim_win_set_buf(0, buf2)
  local win2 = api.nvim_get_current_win()

  local fbuf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(fbuf, 0, -1, false, { 'ccc' })
  local fwin = api.nvim_open_win(fbuf, false, {
    relative = 'editor',
    row = 1,
    col = 1,
    width = 10,
    height = 1,
  })

  jump.setup({ multi_window = false })
  eq(target_windows(win1), { win1 })

  jump.setup({ multi_window = true })
  local wins = target_windows(win1)
  eq(#wins, 2)

  local seen = {}

  for _, win in ipairs(wins) do
    seen[win] = true
  end

  ok(seen[win1] and seen[win2], 'both normal windows are searched')
  ok(not seen[fwin], 'floating windows are skipped')

  api.nvim_win_close(fwin, true)
  api.nvim_win_close(win2, true)
  jump.setup({ multi_window = false })
end)

test('inline_offset: includes every inline hint up to the column', function()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc' })
  local ns = api.nvim_create_namespace('jump-test-inline')
  api.nvim_buf_set_extmark(buf, ns, 0, 1, {
    virt_text = { { 'xx', 'Comment' } },
    virt_text_pos = 'inline',
  })

  eq(inline_offset(buf, 0, 0), 0)
  eq(inline_offset(buf, 0, 1), 2)
  eq(inline_offset(buf, 0, 2), 2)

  -- A hint anchored just after the match start must not shift the label.
  local buf2 = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf2, 0, -1, false, { 'abc' })
  api.nvim_buf_set_extmark(buf2, ns, 0, 0, {
    virt_text = { { 'yy', 'Comment' } },
    virt_text_pos = 'inline',
  })
  eq(inline_offset(buf2, 0, 0), 2, 'a hint at the match start counts')
  eq(inline_offset(buf2, 0, 1), 2, 'a hint before the match counts')
end)

test('e2e: jump to a pinyin match', function()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc你好世界' })
  api.nvim_win_set_buf(0, buf)
  api.nvim_win_set_cursor(0, { 1, 0 })

  vim.schedule(function()
    api.nvim_feedkeys('nhf', 't', false)
  end)

  jump.start()
  eq(api.nvim_win_get_cursor(0), { 1, 3 })
end)

test('e2e: backspace fixes a wrong pinyin key', function()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'abc你好世界' })
  api.nvim_win_set_buf(0, buf)
  api.nvim_win_set_cursor(0, { 1, 0 })

  local bs = api.nvim_replace_termcodes('<Bs>', true, true, true)
  vim.schedule(function()
    api.nvim_feedkeys('nq' .. bs .. 'hf', 't', false)
  end)

  jump.start()
  eq(api.nvim_win_get_cursor(0), { 1, 3 })
end)

if failures > 0 then
  io.write(string.format('\n%d of %d tests failed\n', failures, total))
  os.exit(1)
end

io.write(string.format('\nall %d tests passed\n', total))
