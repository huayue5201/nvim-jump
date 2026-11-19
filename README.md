# The smallest sensible Neovim jump plugin in the west

nvim-jump is a jump plugin similar to
[pounce](https://github.com/rlane/pounce.nvim) and
[flash](https://github.com/folke/flash.nvim), but with a severely reduced
feature set and a small codebase: the jump loop and codec framework are a few
hundred lines of hand-written Lua, plus generated pinyin and Unicode tables.

Usage is simple: press a key to trigger the plugin, type one or more characters
to reduce the number of matches, then press the label to jump to it. Basically
it's like the `/` operator but with the ability to easily jump to a specific
match instead of having to hit `n` a bunch of times:

[![Demo](https://asciinema.org/a/zpRTVO3mQbB5URus.svg)](https://asciinema.org/a/zpRTVO3mQbB5URus)

Compared to other plugins this allows for jumping that's just as fast but
without the mental cost of having to deal with changing labels, a hundred labels
displayed on screen, and so on.

## Fork

This repository is [huayue5201/nvim-jump](https://github.com/huayue5201/nvim-jump),
a fork of [yorickpeterse/nvim-jump](https://github.com/yorickpeterse/nvim-jump).
It keeps the upstream behaviour and adds:

- CJK matching by pinyin initial (see below)
- Optional jumping across windows of the current tab page
- A small codec framework for extensible non-ASCII matching
- Unicode (NFC) normalization of the input query
- A headless test suite

Features are still deliberately few; the upstream plugin is considered complete,
so this fork only adds what is documented here.

## Why?

I've used various jump plugins in the past, but the experience has been mixed.
In terms of features and stability pounce was the best, but it only supports
upper case labels which makes jumping more annoying.

Flash is more powerful but in my experience Folke's plugins tend to be janky
(e.g. weird/buggy behavior), issues just get closed automatically with no
response and maintenance is spotty.

mini.jump2d is a good jump plugin but I don't like its approach to labelling and
jumping as it results in a very noisy window full of labels. Like most mini.nvim
plugins you _can_ extend it (and this is something I experimented with a lot),
but there's only so far this will get you.

leap and others try really hard to be clever about jumping around but in the end
I found using them to be deeply confusing.

This plugin has existed in my own
[dotfiles](https://github.com/yorickpeterse/dotfiles) repository for a while,
and I now deem it stable enough to share it as a standalone plugin.

## Features

- Jump to arbitrary text similar to `/` but without having to press `n` a bunch
  of times
- Labels that remain consistent (as much as possible) as you type more input
- Reduce/correct input by pressing backspace
- Case-insensitive if the input is lower case, case-sensitive if it includes
  capitals
- CJK characters match by their pinyin initial: `nh` jumps to 你好,
  `sj` jumps to 世界
- Optionally jump to matches in any window of the current tab page
- Small codebase so less likely to be riddled with bugs

Feature-wise this plugin is considered complete.

## Requirements

- Neovim 0.11.0 or newer, earlier versions might also work but aren't supported

## Usage

Install the plugin using your favorite plugin manager.

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({ "https://github.com/huayue5201/nvim-jump" })
vim.keymap.set({ 'n', 'x', 'o' }, 's', require('jump').start, {})
```

With lazy.nvim:

```lua
{
  'huayue5201/nvim-jump',
  init = function()
    vim.keymap.set({ 'n', 'x', 'o' }, 's', require('jump').start, {})
  end,
}
```

Or create the mapping yourself after the plugin is loaded (this maps the plugin
to the `s` key):

```lua
vim.keymap.set({ 'n', 'x', 'o' }, 's', require('jump').start, {})
```

While jumping:

- Type characters to narrow the matches. Lower-case input matches
  case-insensitively; input containing a capital is case-sensitive.
- Press `Backspace` (`<C-h>` also works) to delete the last input character.
- Press a label to jump to that match.
- Press `Enter` to jump to the match with the first available label.
- Press `Esc` to cancel.

The plugin works in normal, visual and operator-pending mode because
`require('jump').start` is a plain function; the mapping above covers all three.

The plugin calls `setup()` with the defaults when it loads, so it works without
any configuration. To change the labels, highlight groups or codecs, call
`setup()` before or after loading; the options you pass replace the current
values:

```lua
require('jump').setup({
  labels = 'abcdef'
})
```

The following settings are available (along with their defaults):

```lua
{
  -- The labels that may be used, in order of their preference.
  labels = 'fdsaghjklrewqtyuiopvcxzbnm',

  -- The highlight group to use for match highlights.
  search = 'Search',

  -- The highlight group to use for labels.
  label = 'FlashLabel',

  -- Jump to matches in every window of the current tab page instead of only the
  -- current window. Floating windows are skipped, except the current window.
  multi_window = false,

  -- Character codecs, in order of registration. A codec either maps non-ASCII
  -- characters to alternative ASCII keys (e.g. pinyin initials) or parses a
  -- whole line for context-sensitive scripts; see lua/jump/codec/init.lua.
  codecs = { 'pinyin' },
}
```

For Colemak users you can use the following configuration:

```lua
require('jump').setup({
  labels = 'tnseriaogmplfuwyqbjdhvkzxc',
})
```

The default highlight group for labels is `FlashLabel` so migrating from flash
is easier.

### Chinese (CJK) text

CJK characters are matched both literally and by their pinyin initial, so
jumping into Chinese text does not require switching to an IME:

- `nh` matches 你好, `sj` matches 世界, `nhsj` matches 你好世界
- ASCII is matched literally, so a query can mix both: `a你` or `abn`
- Typing the character itself still works: `你` matches 你
- Pinyin initials ignore case (`N` still matches 你); ASCII input with capitals
  is case-sensitive as usual

The mapping covers the 3755 GB2312 level-1 characters plus the most common
多音字, which get one initial per reading (行 `x`/`h`, 重 `z`/`c`, 长 `c`/`z`).
Characters outside that set are matched literally only. The GB2312 table lives
in `lua/jump/pinyin.lua`; the additional 多音字 initials live in
`lua/jump/codec/pinyin.lua`. The table is only loaded once a buffer actually
contains CJK text.

A single letter can match many characters, so there may be more matches than
labels. Keep typing to narrow them down; matches without a label are still
highlighted, they just cannot be jumped to directly.

### Other scripts

Non-ASCII matching is pluggable through codecs. A codec is a module returning
`keys(char)` (alternative ASCII keys, e.g. a romanization), `parse(line, entries)`
(for scripts whose characters depend on context, e.g. a small kana that changes
the preceding one) and/or `normalize(str)` (compatibility folding of the input
query). `lua/jump/codec/init.lua` documents the contract;
`lua/jump/codec/pinyin.lua` is a short example.

Codecs are loaded lazily by name from `jump.codec.<name>`, so one can also live
in your own configuration as `lua/jump/codec/<name>.lua` on `runtimepath`. All
enabled codecs run, in configuration order, so a kana codec and the pinyin codec
can work on the same line:

```lua
require('jump').setup({ codecs = { 'pinyin', 'kana' } })
```

A character that no codec knows about is still matched literally.

When several matches start at the same place, the longest one wins, and every
character that would extend the query (rather than finish it) is kept away from
the label keys. For example, with a codec whose key is `kya`, typing `ky` never
lets `a` jump away.

Queries are normalized to NFC before matching, so `e` followed by a combining
acute accent matches `é`, marks are put into canonical order first, and Hangul
jamo match the precomposed syllable. Buffer text is assumed to be NFC already
(which is what editors and input methods write); text stored in another
normalization form is matched as-is. Compatibility folding (NFKC: half-width
katakana, compatibility ideographs) is left to codecs through `normalize`.

One limitation of `parse`: the collected entries are matched one after another,
so a line-level codec that fuses several characters into one entry can expose
that entry through its ASCII `keys`, but typing the fused characters literally
will not match it. Right-to-left scripts are not supported: labels are placed by
byte column, which does not follow their visual order.

### Multiple windows

By default only the current window is searched. Enable `multi_window` to search
every window of the current tab page; each match gets a label, and picking one
switches to its window:

```lua
require('jump').setup({ multi_window = true })
```

Floating windows (hover, completion popups, …) are skipped, except the current
window, which is always searched even when it is floating. Other tab pages are
not searched because their labels would not be visible. If the same buffer is
shown in several windows, each visible part is searched independently. The
match's window is selected before the cursor is moved, and the previous
position is added to the jumplist.

### Tests

The repository includes a headless test suite. Run it from the repository root
with Neovim 0.11 or newer:

```sh
nvim --headless --clean -l tests/run.lua
```

## License

All source code in this repository is licensed under the Mozilla Public License
version 2.0, unless stated otherwise. A copy of this license can be found in the
file "LICENSE".
