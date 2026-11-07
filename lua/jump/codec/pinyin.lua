-- Character-level codec: CJK characters match through their pinyin initials.
--
-- The table in `jump.pinyin` maps initials to character groups (3755 GB2312
-- level-1 characters). It is only loaded once a non-ASCII character is actually
-- parsed, so buffers without CJK text never pay for it.

local text = require('jump.text')

local MAP = nil

local function pinyin()
  if MAP then
    return MAP
  end

  local groups = require('jump.pinyin')
  local map = {}

  for letter, chars in pairs(groups) do
    for _, char in ipairs(text.chars(chars)) do
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

  MAP = map
  return map
end

-- The GB2312 sort order assigns every character exactly one initial: the one
-- of the reading that decides its place in the table. For a 多音字 that hides
-- the other common reading, which is often the one the user means (行 háng vs
-- xíng, 长 zhǎng vs cháng). These overrides add the missing initials. They are
-- deliberately conservative: only readings that change the initial letter,
-- and only ones in common use.
local EXTRA = {
  ['行'] = 'h',
  ['长'] = 'z',
  ['重'] = 'c',
  ['朝'] = 'z',
  ['传'] = 'z',
  ['藏'] = 'z',
  ['曾'] = 'c',
  ['参'] = 's',
  ['系'] = 'j',
  ['解'] = 'x',
  ['给'] = 'j',
  ['便'] = 'p',
  ['弹'] = 't',
  ['调'] = 't',
  ['恶'] = 'w',
  ['会'] = 'k',
  ['卡'] = 'q',
  ['单'] = 's',
  ['盛'] = 'c',
  ['省'] = 'x',
  ['宿'] = 'x',
  ['提'] = 'd',
  ['尾'] = 'y',
  ['校'] = 'j',
  ['粘'] = 'n',
  ['识'] = 'z',
  ['石'] = 'd',
  ['区'] = 'o',
  ['乐'] = 'y',
  ['率'] = 's',
  ['番'] = 'p',
  ['否'] = 'p',
  ['尉'] = 'y',
  ['脯'] = 'p',
  ['莘'] = 'sx',
  ['於'] = 'wy',
  ['属'] = 'z',
  ['术'] = 'z',
  ['汤'] = 's',
  ['陶'] = 'y',
  ['厦'] = 's',
  ['蛤'] = 'h',
  ['咖'] = 'g',
  ['咯'] = 'lg',
  ['哦'] = 'e',
  ['冯'] = 'p',
  ['伺'] = 'c',
  ['屏'] = 'b',
  ['强'] = 'j',
  ['圈'] = 'j',
  ['期'] = 'j',
  ['奇'] = 'j',
  ['茄'] = 'j',
  ['折'] = 's',
  ['撮'] = 'z',
  ['攒'] = 'c',
  ['卒'] = 'c',
  ['咀'] = 'z',
  ['龟'] = 'j',
  ['般'] = 'p',
  ['杓'] = 'sb',
  ['乘'] = 's',
  ['查'] = 'z',
  ['车'] = 'j',
  ['臭'] = 'x',
  ['畜'] = 'c',
  ['幢'] = 'z',
  ['禅'] = 'cs',
  ['颤'] = 'z',
  ['澄'] = 'd',
  ['匙'] = 's',
  ['吓'] = 'h',
  ['巷'] = 'h',
  ['亟'] = 'jq',
  ['见'] = 'x',
  ['缴'] = 'z',
  ['矜'] = 'jq',
  ['卷'] = 'q',
  ['壳'] = 'q',
  ['溃'] = 'h',
  ['泌'] = 'b',
  ['秘'] = 'b',
  ['弄'] = 'l',
  ['刨'] = 'b',
  ['埔'] = 'b',
  ['瀑'] = 'b',
  ['栖'] = 'x',
  ['铅'] = 'y',
  ['乾'] = 'g',
  ['磅'] = 'p',
  ['曝'] = 'b',
  ['泊'] = 'p',
  ['拂'] = 'b',
  ['桧'] = 'gh',
  ['夹'] = 'g',
  ['侥'] = 'y',
  ['颈'] = 'g',
  ['纶'] = 'g',
  ['阿'] = 'e',
}

return {
  -- A character may have several initials (多音字), so every letter in its
  -- group string becomes one alternative key.
  keys = function(char)
    if char:byte() < 0x80 then
      return nil
    end

    local initials = pinyin()[char]
    local extra = EXTRA[char]

    if not initials and not extra then
      return nil
    end

    initials = (initials or '') .. (extra or '')

    local keys = {}
    local seen = {}

    for i = 1, #initials do
      local key = initials:sub(i, i)

      if not seen[key] then
        seen[key] = true
        keys[#keys + 1] = key
      end
    end

    return keys
  end,
}
