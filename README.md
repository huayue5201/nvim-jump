# The smallest sensible Neovim jump plugin in the west

nvim-jump is a jump plugin similar to
[pounce](https://github.com/rlane/pounce.nvim) and
[flash](https://github.com/folke/flash.nvim), but with a severely reduced
feature set and as a result a tiny fraction of the code (less than 200 lines of
code).

Usage is simple: press a key to trigger the plugin, type one or more characters
to reduce the number of matches, then press the label to jump to it. Basically
it's like the `/` operator but with the ability to easily jump to a specific
match instead of having to hit `n` a bunch of times:

[![Demo](https://asciinema.org/a/zpRTVO3mQbB5URus.svg)](https://asciinema.org/a/zpRTVO3mQbB5URus)

Compared to other plugins this allows for jumping that's just as fast but
without the mental cost of having to deal with changing labels, a hundred labels
displayed on screen, and so on.

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
- Small codebase so less likely to be riddled with bugs

Feature-wise this plugin is considered complete and extra features (e.g. jumping
between windows) won't be added.

## Requirements

- Neovim 0.11.0 or newer, earlier versions might also work but aren't supported

## Usage

Install the plugin using your favorite plugin manager, then create a mapping
(this maps the plugin to the `s` key):

```lua
vim.keymap.set({ 'n', 'x', 'o' }, 's', require('jump').start, {})
```

If you want to change the labels to use or the highlight groups, use the `setup`
function:

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

The mapping covers the 3755 GB2312 level-1 characters, i.e. the common ones.
Characters outside that set are matched literally only. The table lives in
`lua/jump/pinyin.lua` and is only loaded once a buffer actually contains CJK
text.

A single letter can match many characters, so there may be more matches than
labels. Keep typing to narrow them down; matches without a label are still
highlighted, they just cannot be jumped to directly.

## License

All source code in this repository is licensed under the Mozilla Public License
version 2.0, unless stated otherwise. A copy of this license can be found in the
file "LICENSE".
